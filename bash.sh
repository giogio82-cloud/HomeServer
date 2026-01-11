#!/bin/bash

# set hostname
set -xe
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
AWS_INSTANCE_LOCAL_IPV4=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
test -n "${dns_domain}" && echo "$AWS_INSTANCE_LOCAL_IPV4 ${instance_name}.${dns_domain} ${instance_name}" >> /etc/hosts
hostname ${instance_name}
echo ${instance_name} > /etc/hostname

# update and install required ackages
yum update -y
yum install -y telnet docker nmap python3-boto3  python3-pip

# install cloudwatch agent and load config
if [ $(uname -i) = x86_64 ]; then
  rpm -Uvh https://amazoncloudwatch-agent.s3.amazonaws.com/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
elif [ $(uname -i) = aarch64 ]; then
  rpm -Uhv https://amazoncloudwatch-agent.s3.amazonaws.com/amazon_linux/arm64/latest/amazon-cloudwatch-agent.rpm
fi
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c ssm:CloudWatchAgentConfigLinux

# install zabbix agent
# mongodb and postgresql plugins are dependencies of zabbix agent2
if [ $(uname -i) = x86_64 ]; then
  rpm -Uvh https://repo.zabbix.com/zabbix/6.0/rhel/9/x86_64/zabbix-agent2-plugin-mongodb-6.0.25-release1.el9.x86_64.rpm
  rpm -Uvh https://repo.zabbix.com/zabbix/6.0/rhel/9/x86_64/zabbix-agent2-plugin-postgresql-6.0.25-release1.el9.x86_64.rpm
  rpm -Uvh https://repo.zabbix.com/zabbix/6.0/rhel/9/x86_64/zabbix-agent2-6.0.25-release1.el9.x86_64.rpm
elif [ $(uname -i) = aarch64 ]; then
  rpm -Uhv https://repo.zabbix.com/zabbix/6.0/rhel/9/aarch64/zabbix-agent2-plugin-mongodb-6.0.25-release1.el9.aarch64.rpm
  rpm -Uhv https://repo.zabbix.com/zabbix/6.0/rhel/9/aarch64/zabbix-agent2-plugin-postgresql-6.0.25-release2.el9.aarch64.rpm
  rpm -Uhv https://repo.zabbix.com/zabbix/6.0/rhel/9/aarch64/zabbix-agent2-6.0.25-release1.el9.aarch64.rpm
fi

# configure zabbix agent
sed s/^Hostname=.*/Hostname=${instance_name}/ -i /etc/zabbix/zabbix_agent2.conf
sed s?^Server=.*?Server=monitor.${dns_domain}? -i /etc/zabbix/zabbix_agent2.conf
systemctl enable zabbix-agent2
systemctl restart zabbix-agent2

# set docker defaults
systemctl enable docker
echo '{"live-restore":true,"log-driver":"local","log-opts":{"max-size":"50m","max-file":"10"},"storage-driver":"overlay2"}' > /etc/docker/daemon.json;
systemctl restart docker

# install docker-compose
curl -L https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose

# adding ec2-user to docker group
usermod -aG docker ec2-user

# TODO missing feature compared to old CF code is copying a docker-compose.yml and optionally and environment file to S3.
# then downloading it on the ec2 executing docker-compose up.
# Following is the old CF code. Do NOT uncomment.
# aws s3 sync s3://{s3bucket}/{ResourceName}/ /home/ec2-user/ --exclude "*" --include "*.env"
# aws s3 cp s3://{s3bucket}/{ResourceName}/docker-compose.yml /home/ec2-user/docker-compose.yml
# chown ec2-user:ec2-user /home/ec2-user/*
# if [ -f /home/ec2-user/docker-compose.yml ]; then
#     docker-compose --project-directory /home/ec2-user up --detach
# else
#     echo "no docker compose file. Do not run docker-compose"
# fi

# configure container_user as per developer guidelines
if [ ${create_container_user} = true ]; then
  groupadd container -g 12345
  useradd container -d /home/container -u 12345 -g container -G docker
  sudo install -m 775 -o container -g container -d /srv/container
  sudo install -m 700 -o container -g container -d /home/container/.ssh
  if [ "${container_user_authorized_keys}" ]; then
    echo "${container_user_authorized_keys}" > /home/container/.ssh/authorized_keys
    chown container:container /home/container/.ssh/authorized_keys
    chmod 600 /home/container/.ssh/authorized_keys
  fi
  echo '%container ALL= NOPASSWD: /bin/systemctl start docker' >> /etc/sudoers.d/container
  echo '%container ALL= NOPASSWD: /bin/systemctl stop docker' >> /etc/sudoers.d/container
  echo '%container ALL= NOPASSWD: /bin/systemctl restart docker' >> /etc/sudoers.d/container
  echo '%container ALL= NOPASSWD: /bin/systemctl status' >> /etc/sudoers.d/container
  echo '%container ALL= NOPASSWD: /usr/sbin/reboot' >> /etc/sudoers.d/container
  usermod -a -G container ec2-user
fi

# configure data disk
if [ -e ${data_disk_mapping} ]; then
  echo "Found device ${data_disk_mapping}. Formatting and mounting to ${data_disk_path}."
  mkfs.xfs -q ${data_disk_mapping}
  if [ -d "${data_disk_path}" ]; then
    mount ${data_disk_mapping} /mnt
    rsync -a "${data_disk_path}/" /mnt
    umount /mnt
  else
    mkdir -p ${data_disk_path}
  fi
  echo "${data_disk_mapping} ${data_disk_path} auto defaults 0 2" >> /etc/fstab
  mount ${data_disk_path}
fi

# configure log disk
if [ -e ${log_disk_mapping} ]; then
  echo "Found device ${log_disk_mapping}. Formatting and mounting to ${log_disk_path}."
  mkfs.xfs -q ${log_disk_mapping}
  if [ -d "${log_disk_path}" ]; then
    mount ${log_disk_mapping} /mnt
    rsync -a "${log_disk_path}/" /mnt
    umount /mnt
  else
    mkdir -p ${log_disk_path}
  fi
  echo "${log_disk_mapping} ${log_disk_path} auto defaults 0 2" >> /etc/fstab
  mount ${log_disk_path}
fi

# httpd example, comment out for testing purposes
# sleep 5
# echo "<html><body><h2>$(hostname -f)</h2></body></html>" > index.html
# docker run -d --name=httpd -p "8080:80" -v ./index.html:/usr/local/apache2/htdocs/index.html httpd

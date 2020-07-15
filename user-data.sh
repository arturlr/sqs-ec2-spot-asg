#!/bin/bash
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
WORKING_DIR=/root/sqs-ec2-spot-asg

REGION=$1
ACCOUNT=$2
BUCKET=$3
SQSQUEUE=$4
CLOUDWATCHLOGSGROUP=$5

yum -y --security update

yum -y update aws-cli

yum -y install \
  awslogs jq

#amazon-linux-extras install docker
#sudo usermod -a -G docker ec2-user
#service docker start

echo "Region: $REGION"

aws configure set default.region $REGION

cp -av $WORKING_DIR/awslogs.conf /etc/awslogs/
cp -av $WORKING_DIR/spot-instance-interruption-notice-handler.conf /etc/init/spot-instance-interruption-notice-handler.conf
cp -av $WORKING_DIR/convert-worker.conf /etc/init/convert-worker.conf
cp -av $WORKING_DIR/spot-instance-interruption-notice-handler.sh /usr/local/bin/
cp -av $WORKING_DIR/convert-worker.sh /usr/local/bin

chmod +x /usr/local/bin/spot-instance-interruption-notice-handler.sh
chmod +x /usr/local/bin/convert-worker.sh

sed -i "s|us-east-1|$REGION|g" /etc/awslogs/awscli.conf
sed -i "s|%CLOUDWATCHLOGSGROUP%|$CLOUDWATCHLOGSGROUP|g" /etc/awslogs/awslogs.conf
sed -i "s|%REGION%|$REGION|g" /usr/local/bin/convert-worker.sh
sed -i "s|%SQSQUEUE%|$SQSQUEUE|g" /usr/local/bin/convert-worker.sh

chkconfig awslogs on && service awslogs restart

REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY
docker pull ${REGISTRY}/covid-19-api:latest
docker run --runtime nvidia -p 80:80 --restart always covid-19-api:latest

start spot-instance-interruption-notice-handler
start convert-worker

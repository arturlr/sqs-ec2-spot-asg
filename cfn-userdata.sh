#!/bin/bash -xe
yum -y install git
cd /root && git clone https://github.com/arturlr/sqs-ec2-spot-asg.git
REGION=${AWS::Region} ACCOUNT=${AWS::AccountId} SQSQUEUE=${sqsQueue} CLOUDWATCHLOGSGROUP=${cloudWatchLogsGroup}
bash /root/sqs-ec2-spot-asg/user-data.sh
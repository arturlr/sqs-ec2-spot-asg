#!/bin/bash

BUCKET=$1
SQSARN=$2

sed "s/SQSARN/$SQSARN/" notification.json > notification.sqs
aws s3api put-bucket-notification-configuration --bucket ${BUCKET} --notification-configuration file://notification.sqs
rm notification.sqs
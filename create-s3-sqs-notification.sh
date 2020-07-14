#!/bin/bash

BUCKET=$1
SQSQUEUE=$2

sed -i "s|%SQSQUEUEARN%|arn:aws:sqs:$REGION:$ACCOUNT:$SQSQUEUE|g" $WORKING_DIR/notification.json
aws s3api put-bucket-notification-configuration --bucket ${BUCKET} --notification-configuration file://$WORKING_DIR/notification.json
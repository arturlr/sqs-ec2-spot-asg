#!/bin/bash

BUCKET=$1
SQSNAME=$2
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGION="$(aws s3api get-bucket-location --bucket ${BUCKET} --output text)"

SQSARN="arn:aws:sqs:${REGION}:${ACCOUNT}:${SQSNAME}"

sed "s/SQSARN/$SQSARN/" notification.json > notification.sqs
aws s3api put-bucket-notification-configuration --bucket ${BUCKET} --notification-configuration file://notification.sqs
rm notification.sqs
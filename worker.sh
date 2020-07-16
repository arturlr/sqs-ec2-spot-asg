#!/bin/bash

encode_url () {
  URL=$1
  [ "${URL}x" == "x" ] && { URL="$(cat -)"; }

  echo ${URL} | sed -e 's| |%20|g' \
  -e 's|!|%21|g' \
  -e 's|#|%23|g' \
  -e 's|\$|%24|g' \
  -e 's|%|%25|g' \
  -e 's|&|%26|g' \
  -e "s|'|%27|g" \
  -e 's|(|%28|g' \
  -e 's|)|%29|g' \
  -e 's|*|%2A|g' \
  -e 's|+|%2B|g' \
  -e 's|,|%2C|g' \
  -e 's|/|%2F|g' \
  -e 's|:|%3A|g' \
  -e 's|;|%3B|g' \
  -e 's|=|%3D|g' \
  -e 's|?|%3F|g' \
  -e 's|@|%40|g' \
  -e 's|\[|%5B|g' \
  -e 's|]|%5D|g'
}

INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=%REGION%
S3BUCKET=%S3BUCKET%
SQSQUEUE=%SQSQUEUE%
AUTOSCALINGGROUP=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=aws:autoscaling:groupName" | jq -r '.Tags[0].Value')

while sleep 5; do 

  JSON=$(aws sqs --output=json get-queue-attributes \
    --queue-url $SQSQUEUE \
    --attribute-names ApproximateNumberOfMessages)
  MESSAGES=$(echo "$JSON" | jq -r '.Attributes.ApproximateNumberOfMessages')

  if [ $MESSAGES -eq 0 ]; then

    continue

  fi

  JSON=$(aws sqs --output=json receive-message --queue-url $SQSQUEUE)
  RECEIPT=$(echo "$JSON" | jq -r '.Messages[] | .ReceiptHandle')
  BODY=$(echo "$JSON" | jq -r '.Messages[] | .Body')

  if [ -z "$RECEIPT" ]; then

    logger "$0: Empty receipt. Something went wrong."
    continue

  fi

  logger "$0: Found $MESSAGES messages in $SQSQUEUE. Details: JSON=$JSON, RECEIPT=$RECEIPT, BODY=$BODY"

  INPUT=$(echo "$BODY" | jq -r '.Records[0] | .s3.object.key')
  FNAME=$(echo $INPUT | rev | cut -f2 -d"." | rev | tr '[:upper:]' '[:lower:]')
  FEXT=$(echo $INPUT | rev | cut -f1 -d"." | rev | tr '[:upper:]' '[:lower:]')

  if [ "$FEXT" = "zip" -o "$FEXT" = "ZIP" ]; then

    logger "$0: Found work. Details: INPUT=$INPUT, FNAME=$FNAME, FEXT=$FEXT"

    logger "$0: Running: aws autoscaling set-instance-protection --instance-ids $INSTANCE_ID --auto-scaling-group-name $AUTOSCALINGGROUP --protected-from-scale-in"

    aws autoscaling set-instance-protection --instance-ids $INSTANCE_ID --auto-scaling-group-name $AUTOSCALINGGROUP --protected-from-scale-in

    # create an encoded URL https://<bucket-name>.s3.amazonaws.com/<object or key name>

    # run curl - curl -X GET "http://localhost/predict/?input_file=https%3A%2F%2Fwww.dropbox.com%2Fs%2Fqw5kblwibm6wgwz%2Fsingle_series.zip%3Fdl%3D1&format=tiff" -H "accept: text/plain" -o /tmp/file.tiff

    # aws s3 cp s3://$S3BUCKET/$INPUT /tmp

    # echo { "code": 1, "msg": "Ready"} > /tmp/file.zip.status

    # aws s3 cp s3://$S3BUCKET/$INPUT /tmp

    sleep 60

    logger "$0: Running: aws sqs --output=json delete-message --queue-url $SQSQUEUE --receipt-handle $RECEIPT"

    aws sqs --output=json delete-message --queue-url $SQSQUEUE --receipt-handle $RECEIPT

    logger "$0: Running: aws autoscaling set-instance-protection --instance-ids $INSTANCE_ID --auto-scaling-group-name $AUTOSCALINGGROUP --no-protected-from-scale-in"

    aws autoscaling set-instance-protection --instance-ids $INSTANCE_ID --auto-scaling-group-name $AUTOSCALINGGROUP --no-protected-from-scale-in

  else

    logger "$0: Skipping message - file not of type zip. Deleting message from queue"

    aws sqs --output=json delete-message --queue-url $SQSQUEUE --receipt-handle $RECEIPT

  fi

done
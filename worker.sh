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
  S3TMP=$(echo $INPUT | rev | cut -f2 -d"." | rev | tr '[:upper:]' '[:lower:]')
  FNAME=$(basename $INPUT)
  FNAME_NO_SUFFIX="$(basename $INPUT .zip)"
  FEXT=$(echo $INPUT | rev | cut -f1 -d"." | rev | tr '[:upper:]' '[:lower:]')

  if [ "$FEXT" = "zip" -o "$FEXT" = "ZIP" ]; then

    # Amplfy uses semicolon at the key and it gets encoded. This is for decode it
    S3KEY=$(echo ${INPUT} | sed "s/%3A/:/")
    S3KEY_NO_SUFFIX=$(echo ${S3TMP} | sed "s/%3A/:/")

    logger "$0: Found work. Details: INPUT=$INPUT, FNAME=$FNAME, FEXT=$FEXT"

    logger "$0: Running: aws autoscaling set-instance-protection --instance-ids $INSTANCE_ID --auto-scaling-group-name $AUTOSCALINGGROUP --protected-from-scale-in"

    aws autoscaling set-instance-protection --instance-ids $INSTANCE_ID --auto-scaling-group-name $AUTOSCALINGGROUP --protected-from-scale-in

    # Updating status
    echo '{ "code": 0, "msg": "Processing"}' > /tmp/${FNAME}.status
    aws s3 cp /tmp/${FNAME}.status s3://$S3BUCKET/$S3KEY.status    

    # Create the encoding for the URL that will be sent to the model
    URL="https://$S3BUCKET.s3.amazonaws.com/$KEY"

    ENCODED_URL=$(encode_url ${URL})

    logger "$0: Start model processing"

    # Submitting file to the model
    curl -X GET "http://localhost/predict/?input_file=${ENCODED_URL}&format=tiff" -H "accept: text/plain" -o /tmp/$FNAME_NO_SUFFIX.tiff

    logger "$0: END model processing"

    # saving result file
    aws s3 cp /tmp/$FNAME_NO_SUFFIX.tiff s3://$S3BUCKET/$S3KEY_NO_SUFFIX.tiff

    logger "$0: $FNAME_NO_SUFFIX.tiff copied to bucket"

    # Updating status
    echo '{ "code": 0, "msg": "Processing"}' > /tmp/${FNAME}.status
    aws s3 cp /tmp/${FNAME}.status s3://$S3BUCKET/$S3KEY.status

    # pretend to do work for 60 seconds in order to catch the scale in protection
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
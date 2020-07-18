#!/bin/bash

urldecode() { : "${*//+/ }"; echo -e "${_//%/\\x}"; }

urlencode() {
	local LANG=C i c e=''
	for ((i=0;i<${#1};i++)); do
                c=${1:$i:1}
		[[ "$c" =~ [a-zA-Z0-9\.\~\_\-] ]] || printf -v c '%%%02X' "'$c"
                e+="$c"
	done
        echo "$e"
}

update_status () {
    CODE=$1
    MSG=$2
    echo "{ \"code\": $CODE, \"msg\": \"$MSG\" }" > /tmp/${FNAME}.status    
    aws s3 cp /tmp/${FNAME}.status s3://$S3BUCKET/$S3KEY.status

}

INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=%REGION%
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

  S3BUCKET=$(echo "$BODY" | jq -r '.Records[0] | .s3.bucket.name')
  INPUT=$(echo "$BODY" | jq -r '.Records[0] | .s3.object.key')
  S3KEY=$(urldecode $INPUT | tr '[:upper:]' '[:lower:]')

  S3KEY_NO_SUFFIX=$(echo $S3KEY | rev | cut -f2 -d"." | rev)
  FNAME=$(basename $S3KEY)
  FNAME_NO_SUFFIX="$(basename $S3KEY .zip)"
  FEXT=$(echo $S3KEY | rev | cut -f1 -d"." | rev)

  if [ "$FEXT" = "zip" ]; then

    logger "$0: Found work. Details: S3KEY=$S3KEY, FNAME=$FNAME, FNAME_NO_SUFFIX=$FNAME_NO_SUFFIX, FEXT=$FEXT, S3KEY_NO_SUFFIX=$S3KEY_NO_SUFFIX"

    logger "$0: Running: aws autoscaling set-instance-protection --instance-ids $INSTANCE_ID --auto-scaling-group-name $AUTOSCALINGGROUP --protected-from-scale-in"

    aws autoscaling set-instance-protection --instance-ids $INSTANCE_ID --auto-scaling-group-name $AUTOSCALINGGROUP --protected-from-scale-in

    # Updating status
    update_status "0" Processing

    # Create the encoding for the URL that will be sent to the model
    URL="https://$S3BUCKET.s3.amazonaws.com/$S3KEY"

    ENCODED_URL=$(urlencode ${URL})

    logger "$0: Start model processing"

    # Submitting file to the model
    logger "$0: http://localhost/predict/?input_file=${ENCODED_URL}&format=tiff""
    curl -X GET "http://localhost/predict/?input_file=${ENCODED_URL}&format=tiff" -H "accept: text/plain" -o /tmp/$FNAME_NO_SUFFIX.tiff

    logger "$0: END model processing"

    # saving result file
    aws s3 cp /tmp/$FNAME_NO_SUFFIX.tiff s3://$S3BUCKET/$S3KEY_NO_SUFFIX.tiff

    logger "$0: $FNAME_NO_SUFFIX.tiff copied to bucket"

    # Updating status
    update_status "1" Ready

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
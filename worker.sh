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

process_file () {
    
    logger "$0: Running: aws autoscaling set-instance-protection --instance-ids $INSTANCE_ID --auto-scaling-group-name $AUTOSCALINGGROUP --protected-from-scale-in"
    aws autoscaling set-instance-protection --instance-ids $INSTANCE_ID --auto-scaling-group-name $AUTOSCALINGGROUP --protected-from-scale-in

    # Updating status
    update_status "1" Processing

    # Copying the ZIP CT-Scan file
    aws s3 cp s3://$S3BUCKET/$S3KEY /tmp/$FNAME
    FILE_DATE=$(aws s3 ls s3://$S3BUCKET/$S3KEY | grep -v status | awk -F'[^0-9]*' '{print $1$2$3$4$5}')

    logger "$0: Start model processing"

    # Submitting file to the model
    curl -X POST -F "input_file=@/tmp/$FNAME;format=png" http://localhost/predict/ -o /tmp/$FNAME_NO_SUFFIX-png.zip

    logger "$0: END model processing"

    # Unzipping the png files
    mkdir -p /tmp/png/$FNAME_NO_SUFFIX    
    unzip -j /tmp/$FNAME_NO_SUFFIX-png.zip -d /tmp/png/$FNAME_NO_SUFFIX
    # Unzipping the dcm files
    mkdir -p /tmp/dcm/$FNAME_NO_SUFFIX
    unzip -j /tmp/$FNAME -d /tmp/dcm/$FNAME_NO_SUFFIX

    # Create the JSON File
    DCMS=""
    for file in /tmp/dcm/$FNAME_NO_SUFFIX/*; do
      DCMS+="\"https://d2o8vcf7ix9uyt.cloudfront.net/dcm/$FNAME_NO_SUFFIX-$FILE_DATE/$(basename $file)\",\n"
    done
    sed -i "s|%DICOM_FILES%|$DCMS|g" /root/sqs-ec2-spot-asg/data.js
    echo $DCMS

    # Copying to the public bucket
    aws s3 cp --recursive /tmp/dcm/$FNAME_NO_SUFFIX s3://$S3BUCKET/dcm/$FNAME_NO_SUFFIX-$FILE_DATE/
    aws s3 cp --recursive /tmp/png/$FNAME_NO_SUFFIX s3://$S3BUCKET/png/$FNAME_NO_SUFFIX-$FILE_DATE/

    # Updating status
    update_status "2" Ready    

    logger "$0: Running: aws sqs --output=json delete-message --queue-url $SQSQUEUE --receipt-handle $RECEIPT"

    aws sqs --output=json delete-message --queue-url $SQSQUEUE --receipt-handle $RECEIPT

    logger "$0: Running: aws autoscaling set-instance-protection --instance-ids $INSTANCE_ID --auto-scaling-group-name $AUTOSCALINGGROUP --no-protected-from-scale-in"

    aws autoscaling set-instance-protection --instance-ids $INSTANCE_ID --auto-scaling-group-name $AUTOSCALINGGROUP --no-protected-from-scale-in

    sleep 5

}

INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=%REGION%
PUBLICBUCKET=%PUBLICBUCKET%
SQSQUEUE=%SQSQUEUE%
AUTOSCALINGGROUP=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=aws:autoscaling:groupName" | jq -r '.Tags[0].Value')

while :;do 

  # Spot instance interruption notice detection
  if [ ! -z $(curl -Isf http://169.254.169.254/latest/meta-data/spot/instance-action) ]; then
    logger "[$0]: spot instance interruption notice detected"
    break 
  fi

  JSON=$(aws sqs --output=json get-queue-attributes \
    --queue-url $SQSQUEUE \
    --attribute-names ApproximateNumberOfMessages)
  MESSAGES=$(echo "$JSON" | jq -r '.Attributes.ApproximateNumberOfMessages')

  if [ $MESSAGES -eq 0 ]; then
    sleep 60
    logger "$0: No messages to process. sleeping for 60 seconds."
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

    aws s3 cp s3://$S3BUCKET/$S3KEY.status /tmp/${FNAME}.status

    if [ -f "/tmp/${FNAME}.status" ]; then
      STATUS_CODE=$(cat /tmp/${FNAME}.status | jq -r '.code')
      logger "$0: ${FNAME}.status = $STATUS_CODE"
    else 
      update_status "3" "Status file not found"
    fi

    if [ $STATUS_CODE -eq 0 ]; then
      process_file      
    else
      logger "$0: ${FNAME} was probably processed by another worker"
    fi
    
  else

    logger "$0: Skipping message - file not of type zip. Deleting message from queue"
    aws sqs --output=json delete-message --queue-url $SQSQUEUE --receipt-handle $RECEIPT

  fi

done
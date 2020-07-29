from pydicom import dcmread
import zipfile
import os
import json
import sys
import boto3
import logging
import html
import urllib.parse
import ntpath

queueUrl = os.getenv('queueUrl')

s3 = boto3.resource('s3')

sqs = boto3.resource('sqs')
queue = sqs.Queue(queueUrl)

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def saveErrorStatusMsg(s3bucket, key, msg):
    txtMsg = '{ "code": 3, "msg": ' + msg +  '}'
    s3.Bucket(s3bucket).upload_file(txtMsg,key)

def deleteMessage():
    response = queue.receive_messages(
        AttributeNames=['All'],
        MaxNumberOfMessages=10,
        VisibilityTimeout=10,
        WaitTimeSeconds=10
    )

    for message in response:
        sqsEvent = message.body
        sqsFile = urllib.parse.unquote(sqsEvent["Records"][0]["s3"]["object"]["key"])
        sqsbucket = urllib.parse.unquote(sqsEvent["Records"][0]["s3"]["bucket"]["name"])

        if sqsFile == zipFileKey:
            logger.info("found it")
            rsp = message.delete
            logger.info(rsp)

def ziptest(filename):
    file_count = 0
    try:
        zipfile.is_zipfile(filename)        
    except:
        logger.error("This file is not a Zip file")
        return "Error: This file is not a Zip file"
    zipfile.ZipFile(filename).extractall("/tmp/testfolder")
    logger.info("Extracting zip files")
    files = []
    for r, d, f in os.walk("/tmp/testfolder"):
        for file in f:
            files.append(os.path.join(r, file))
    if len(file) == 0:
        return "Error: This file is not a Zip file"
    for f in files:
        try:
            ds = dcmread(f)
            file_count += 1
        except:
            logger.error("This file is not a DCM file")
            return "Error: Zip does not contain DCM files"

    logger.info("Validated " + str(file_count) + " dcm files")
    return ""


def handler(event, context):

    #logger.info(event)
    statusFile = urllib.parse.unquote(event["Records"][0]["s3"]["object"]["key"])
    bucket = urllib.parse.unquote(event["Records"][0]["s3"]["bucket"]["name"])

    obj = s3.Object(bucket, statusFile)
    status = json.loads(obj.get()['Body'].read())
    if status["code"] != 0:
        logger.info("code is not 0 - skipping")

    zipFileKey = statusFile[0:len(statusFile)-7]
    zipfileName = ntpath.basename(zipFileKey)

    s3.Bucket(bucket).download_file(zipFileKey, '/tmp/' + zipfileName)

    rst = ziptest('/tmp/' + zipfileName)

    if (rst[:5].lower()) == "error":
        saveErrorStatusMsg(bucket, statusFile, rst)
        deleteMessage()
        return False

    


        


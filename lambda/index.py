from pydicom import dcmread
from zipfile import ZipFile
import os
def ziptest(filename):
    ZipFile(filename).extractall("testfolder")
    files = []
    for r, d, f in os.walk("testfolder"):
        for file in f:
            files.append(os.path.join(r, file))
    if len(file) == 0:
        return False
    for f in files:
        try:
            ds = dcmread(f)
        except:
            print("This file is not a DCM file")
            return False
    return True
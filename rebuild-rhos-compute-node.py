#!/usr/bin/env python
import sys
import commands
import getpass
import re

def rebuild(host,mgmt):
    print("Attempting to rebuild "+host)
    print("Please enter the username to authenticate to the foreman: "),
    USER=sys.stdin.readline().rstrip()
    PASSWORD=getpass.getpass("Please enter the password: ").rstrip()
    curlcommand="curl -H \"Content-Type: application/json\" -k -u "+USER+":"+PASSWORD+"  https://theforeman.eng.lab.tlv.redhat.com/api/hosts/"+host+" -X PUT -d '{\"build\":true}'" 
    (status,output)=commands.getstatusoutput(curlcommand)
    match=re.search('"build":true',output)
    if match:
        print(match.group(0))
    else:
        print("Something went wrong running "+curlcommand+" Exiting...")
        sys.exit(status)
    ipmicommand="ipmitool -I lanplus -H "+mgmt+" -U USERID -P PASSW0RD chassis power cycle"
    (status,output)=commands.getstatusoutput(ipmicommand)
    print(output)
    if status != 0:
        print("Something went wrong running \""+ipmicommand+"\". Exiting...")
        sys.exit(status)
    
def select_host(hosts):
    PREFIX="rhos-compute-node-"
    SUFFIX=".lab.eng.rdu2.redhat.com"
    myhosts=[]
    for index in range(0,len(hosts)):
        myhosts.append([PREFIX+hosts[index]+SUFFIX,PREFIX+hosts[index]+"-mm.mgmt"+SUFFIX])
    print("Select host for rebuilding")
    for num in range(0,len(myhosts)):
        print(str(num+1)+". "+myhosts[num][0])
    print("Selection: ")
    try:
        SELECTION=int(sys.stdin.readline())
    except(ValueError):
        print("Wrong selection. Check your input. Exiting...")
        sys.exit(1)
    if SELECTION < 1 or SELECTION > len(myhosts):
        print("Wrong selection. Exiting...")
        sys.exit(1)
    rebuild(myhosts[SELECTION-1][0],myhosts[SELECTION-1][1])
    

def main():
    myhosts=["03","07","08","11"]
    select_host(myhosts)

if __name__  == '__main__':
    main()

# Collecting data for troubleshooting with the 'snmpwalk' utility
## Problem 
You are having trouble collecting SNMP metrics from your device.

## Solution 
The snmpwalk utility is a useful tool for troubleshooting various SNMP challenges you may encounter. Because ktranslate runs on the host network of the Linux host that Docker is running on top of, it is an accurate measurement of whether or not your devices are responding to SNMP requests and what specifically they are responding with.

You can install snmpwalk by running the relevant command for your distro

```apt-get install snmp```

or 

```yum install net-snmp-utils```



## Connectivity testing 
You can test connectivity to your SNMP devices with a basic test to gather the System Object Identifier (SysOID) of the device. If it's successful, the configuration of SNMP on the device and the network connectivity between the Docker host and the device are working well. If it fails, you'll need to validate the settings in your internal network.

Run one of the following depending on your SNMP device version:

### SNMP v2c example

```snmpwalk -v 2c -On -c $COMMUNITY $IP_ADDRESS .1.3.6.1.2.1.1.2.0```

Where $COMMUNITY is your SNMP community string and $IP_ADDRESS is the target device IP.

### SNMP v3 example

```snmpwalk -v 3 -l $LEVEL -u $USERNAME -a $AUTH_PROTOCOL -A $AUTH_PASSPHRASE -x $PRIV_PROTOCOL -X $PRIV_PASSPHRASE -ObentU -Cc $IP_ADDRESS .1.3.6.1.2.1.1.2.0```
```
$LEVEL == noAuthNoPriv | authNoPriv | authPriv
$USERNAME == SNMP v3 User
$AUTH_PROTOCOL == MD5 | SHA
$AUTH_PASSPHRASE == Authentication passphrase
$PRIV_PROTOCOL == DES | AES
$PRIV_PASSPHRASE == Privacy passphrase
$IP_ADDRESS == target device IP
```

The following is an example of the expected output after running snmpwalk:
```.1.3.6.1.2.1.1.2.0 = OID: .1.3.6.1.4.1.9.1.46```






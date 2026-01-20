# KtransToGrafana
This repo is an example of a quick time to value deployment of [Ktranslate](https://github.com/kentik/ktranslate/) writing to a [Grafana Cloud](https://grafana.com/products/cloud/) OTLP endpoint. While there are countless approaches to accomplish this I am hoping to provide a simple, functional example without requiring too much Linux or Alloy expertise. You should be able to have SNMP data showing up in your Grafana account in about 5 minutes, 10 if you get really jammed up on Vim.

If you run into problems you can check the ```troubleshooting``` folder in this repo for some more help.

## Architecture
This example will provide you with a docker compose configuration to launch 3 containers; one running Ktranslate for receiving netflow data (supports the most common formats such as netflow 5/9/sflow/ipfix/nbar/pan/etc), another running Ktranslate to do SNMP device discovery and polling, and another running a stripped down Grafana Alloy agent to forward OTLP data from the previous containers. 
Feel free to fork this repo or PR changes if you find that we can make this more simple or more 'production-ready' 

## Usage Instructions
Start with an Ubuntu Linux system (also tested under Windows WSL).

Install Docker and Docker Compose as per their [documentation](https://docs.docker.com/compose/install/linux/#install-using-the-repository)
Run the following to ensure this is completed successfully
```docker engine
docker run hello-world
```
and
```docker compose
docker compose version
```

Make sure you are in the correct directory where you intend to store all the relevant files for ktranslate

```
pwd
```

Clone this repo or your fork into the folder
```
git clone https://github.com/Mesverrum/KtransToGrafana.git
cd KtransToGrafana/
```

There are 3 .sample files in here that you will need to copy and modify to your requirements
```
cp .env.sample .env
cp snmp.yaml.sample snmp.yaml
cp config.alloy.sample config.alloy
```

### ENV variables
Setting up the .env file is the first step. Log in to your Grafana Cloud account and search for `Add new connection` then in that screen search for `otlp`, and select the `OpenTelemetry` tile. 
Create a new token or use an existing one. 
In this case you can skip over the instructions for installing Alloy and go straight to `Append the generated configuration to your configuration file` and scroll to the bottomr to find the pieces you will need to pass into  container. You should grab the URL of the client endpoint from the `otelcol.exporter.otlphttp` section and the username/password from the `otelcol.auth.basic` section.  

**You do not need to deploy any collector at this time, we just want to copy out the credentials for our environmental variables.**

```
otelcol.exporter.otlphttp "grafana_cloud" {
	client {
		endpoint = "https://otlp-gateway-prod-abcxyz.grafana.net/otlp"
		auth     = otelcol.auth.basic.grafana_cloud.handler
	}
}

otelcol.auth.basic "grafana_cloud" {
	username = "0000000"
	password = "glc_foo="
}  
```

In your terminal edit the `.env` file
```
vim .env
```

Switch to INSERT mode by pressing `i` on your keyboard and remove the placeholders and paste in the values you got from your Grafana Cloud web console to set the correct values for the below variables, you do not need quotes.

GC_OTLP_URL

GC_OTLP_ACCOUNT

GC_OTLP_KEY


When you have all 3 populated then press `Esc` and type `:wq` to save the changes and exit Vim.

Now you will read this file into the ENV variables for our session. 
```
export $(xargs < .env)
```
You can spot check that the variables were set correctly by running this and making sure it shows your URL.
```
echo $GC_OTLP_URL
```

Keep in mind this command is specific to our session, disconnecting or rebooting will lose these variables. There are other ways to make them permanent or available to other users as necessary.

The `config.alloy` file is already configured to use those ENV variables, so there should not be a need to modify this file unless you have modifications to make that are unrelated to ktranslate.

### snmp.yaml
The last piece to modify is the `snmp.yaml` file. This file manages the config of the Ktranslate container that is used to poll SNMP devices. The [documentation](https://github.com/kentik/ktranslate/wiki) on this in the main project Github is a little sparse right now, but more detailed documentation on the many options can be found [here](https://docs.newrelic.com/docs/network-performance-monitoring/advanced/advanced-config/). Grafana and OTEL specific documentation will be added in the coming months.

For the sake of a quick example you can open the `snmp.yaml` file in Vim and press `i` to go into `INSERT` mode to make changes. The first section is discovery where you can set the CIDR IP ranges for SNMP enabled devices you want to run a discovery against. For specific devices you can enter their IP with /32 at the end.  
The `default_communities` section can hold a list of SNMP v2 community strings to test against the devices.  

For SNMP v3 I would recommend adding an "other_v3s" block like this inside the discovery block
```
discovery:
  other_v3s:
  - user_name: my_user_1
    authentication_protocol: my_auth_protocol_1
    authentication_passphrase: my_auth_pass_1
    privacy_protocol: my_priv_protocol_1
    privacy_passphrase: my_priv_pass_1
    context_engine_id: ""
    context_name: ""
  - user_name: my_user_2
    authentication_protocol: my_auth_protocol_2
    authentication_passphrase: my_auth_pass_2
    privacy_protocol: my_priv_protocol_2
    privacy_passphrase: my_priv_pass_2
    context_engine_id: ""
    context_name: ""
```

The `devices` section will be blank initially, but as the discovery runs the container will update this file with the information of devices that it has connected with. This forms the target list that ktranslate will use after the discovery job is complete to poll the devices. When Ktranslate discovers a device it will collect the SysObjectID and based on that it does a lookup against the library of device profiles found in this repo [https://github.com/kentik/snmp-profiles](https://github.com/kentik/snmp-profiles).
The profile repo contains a curated list of OIDs to collect that should provide useful information. This eliminates the pain of hunting down MIBs and processing them through the generator and then cleaning up the resulting output.

Once you have your CIDR and credentials set you can press `Esc` and type in `:wq` to save your changes.

Depending which account you are currently logged into on your server there can be a situation where the docker container does not end up with the correct permission to edit the devices list in the `snmp.yaml` during discovery. To prevent this issue run the following command to ensure that the file is accessible by the container's user:
```
sudo chown 1000:1000 snmp.yaml
```

### Running it
With your variables set and your target CIDR subnets in place you can now run the containers, from the same working directory we have been in run
```
docker compose up -d
```
You will see the latest container images get downloaded and as long as we did no introduce any syntax errors you should see ktranslate importing the collection of profiles and begin discovery. If you have a reasonable range of subnets this should only take a minute or two and then you will see devices being mapped to profiles and the relevant OIDs start getting polled. If you don't see any major errors you can return to your terminal session by pressing `CTRL+Z` (unless you are using vscode and it is intercepting the key combo...)


## Data in Grafana

Within a couple minutes of seeing Ktranslate polling your devices there should be data in your Grafana Cloud's default Prometheus data source. The metrics will have names that start with `kentik_snmp_*` and have relevant labels such as `device_name` and `if_interface_name` based on the SNMP profile that this model was associated with. Network gear is all over the place in terms of cardinality, so most people tend to figure you will collect about 1,000 active series per network device, but in practice something simple like a UPS might create 50 AS and a large core switch or load balancer might have 10,000.

Because of how high volume flow data is this configuration has Ktranslate converting raw flow data into a collection of metric series using the rollups arguments in the `compose.yaml` file.  This can be much more cost effective to store and to query than raw flow log lines.  The [Sankey panel](https://grafana.com/grafana/plugins/netsage-sankey-panel/) in Grafana works well to visualize this data after applying the `Group by` transformation to sum up the total bytes.


I've included the JSON for a flow dashboard you can import to your Grafana, more to come for various SNMP device use cases as I get time.

# Contact me
Feel free to reach out to me via Issues and PR's in this repo or contact me directly, marcnetterfield@gmail.com

# appd_es_dr_tool
Usage: appd_es_dr_tool.sh [-h] [-v] [-r] [-d] [-f frequency] [-k keep] -m primary|secondary|cleanup -c config_file

Manage AppDynamics Events Service automatic backup & restore

Available options:

-h, --help        Print this help and exit<br>
-v, --verbose     Print script debug info<br>
-r, --remote      Enable remote update of snapshot id file for read-only filesystems. Default: false<br>
-c, --config      Path to config file<br>
-m, --mode        Run mode. Valid options are: primary|secondary|cleanup<br>
-d, --daemon      Daemon mode. Default: false<br>
-f, --frequency   In daemon mode, set the frequency in seconds at which the update is performed. Default: 3600<br>
-k, --keep        In cleanup mode, number of snapshots to keep in repository. Default: 1<br>


Example:

* Run on Primary master node to periodically take snapshots:
./appd_es_dr_tool.sh -m primary -c standard.cfg -d -f 1800<br>
* Run on DR master node to periodically restore snapshots:
./appd_es_dr_tool.sh -m secondary -c standard.cfg -d -f 900<br>
* Run on Primary master node to periodically clean up snapshots:
./appd_es_dr_tool.sh -m cleanup -c standard.cfg -d -f 1800<br>

Content of the config file:

primary_es_url=http://<es.primary.host>:9200<br>
secondary_es_url=http://<es.secondary.host>:9200<br>
primary_es_path=<appd_platform_home_primary>/product/events-service<br>
secondary_es_path=<appd_platform_home_secondary>/product/events-service<br>
primary_es_repo_path=<appd_platform_home_primary>/product/events-service/data/appdynamics-analytics-backup<br>
secondary_es_repo_path=<appd_platform_home_secondary>/product/events-service/data/appdynamics-analytics-backup<br>
es_repo_name=appdynamics-analytics-backup<br>

Notes:
* In Primary mode:
We do a snapshot if :
  - there is no snapshot yet
  - there is no snapshot in progress already
  - secondary has restored previous snapshot

* In Secondary mode:
We do snapshot restore if :
  - there is at least one snapshot
  - there is no snapshot restore in progress
  - there is a new snapshot that has not been restored
 
* In a DR scenario, you want to use a config file with inverted values from the standard config (eg. primary settings become secondary & vice versa). Then you run primary mode on the live DR cluster and secondary on the main cluster.

# Architecture icon library

Shared across every module. Reference from a slide in `<module>/_render/` as:

```xml
<image href="../../_icons/aws/analytics/redshift.png" x="756" y="396" width="66" height="66"/>
```

Regenerate with `python sync_icons.py`. Source: the icon set bundled with the
`diagrams` package, derived from the official AWS Architecture Icons.
For a client-facing deliverable, consider the canonical pack at
<https://aws.amazon.com/architecture/icons/> — it is updated quarterly and a
generation ahead of this bundle on some services.

**605 icons available.**

## aws

**`aws/analytics/`** (29) — `amazon-opensearch-service` · `analytics` · `athena` · `cloudsearch-search-documents` · `cloudsearch` · `data-lake-resource` · `data-pipeline` · `elasticsearch-service` · `emr-cluster` · `emr-engine-mapr-m3` · `emr-engine-mapr-m5` · `emr-engine-mapr-m7` · `emr-engine` · `emr-hdfs-cluster` · `emr` · `glue-crawlers` · `glue-data-catalog` · `glue` · `kinesis-data-analytics` · `kinesis-data-firehose` · `kinesis-data-streams` · `kinesis-video-streams` · `kinesis` · `lake-formation` · `managed-streaming-for-kafka` · `quicksight` · `redshift-dense-compute-node` · `redshift-dense-storage-node` · `redshift`

**`aws/ar/`** (2) — `ar-vr` · `sumerian`

**`aws/blockchain/`** (4) — `blockchain-resource` · `blockchain` · `managed-blockchain` · `quantum-ledger-database-qldb`

**`aws/business/`** (4) — `alexa-for-business` · `business-applications` · `chime` · `workmail`

**`aws/compute/`** (63) — `app-runner` · `application-auto-scaling-rounded` · `application-auto-scaling` · `batch-rounded` · `batch` · `compute-optimizer` · `compute-rounded` · `compute` · `ec2-ami` · `ec2-auto-scaling` · `ec2-container-registry-image` · `ec2-container-registry-registry` · `ec2-container-registry-rounded` · `ec2-container-registry` · `ec2-elastic-ip-address` · `ec2-image-builder` · `ec2-instance` · `ec2-instances` · `ec2-rescue` · `ec2-rounded` · `ec2-spot-instance` · `ec2` · `elastic-beanstalk-application` · `elastic-beanstalk-deployment` · `elastic-beanstalk-rounded` · `elastic-beanstalk` · `elastic-container-service-container` · `elastic-container-service-rounded` · `elastic-container-service-service-connect` · `elastic-container-service-service` · `elastic-container-service-task` · `elastic-container-service` · `elastic-kubernetes-service-rounded` · `elastic-kubernetes-service` · `fargate-rounded` · `fargate` · `lambda-function` · `lambda-rounded` · `lambda` · `lightsail-rounded` · `lightsail` · `local-zones` · `outposts-rounded` · `outposts` · `serverless-application-repository-rounded` · `serverless-application-repository` · `thinkbox-deadline-rounded` · `thinkbox-deadline` · `thinkbox-draft-rounded` · `thinkbox-draft` · `thinkbox-frost-rounded` · `thinkbox-frost` · `thinkbox-krakatoa-rounded` · `thinkbox-krakatoa` · `thinkbox-sequoia-rounded` · `thinkbox-sequoia` · `thinkbox-stoke-rounded` · `thinkbox-stoke` · `thinkbox-xmesh-rounded` · `thinkbox-xmesh` · `vmware-cloud-on-aws-rounded` · `vmware-cloud-on-aws` · `wavelength`

**`aws/cost/`** (6) — `budgets` · `cost-and-usage-report` · `cost-explorer` · `cost-management` · `reserved-instance-reporting` · `savings-plans`

**`aws/database/`** (34) — `aurora-instance` · `aurora` · `database-migration-service-database-migration-workflow` · `database-migration-service` · `database` · `documentdb-mongodb-compatibility` · `dynamodb-attribute` · `dynamodb-attributes` · `dynamodb-dax` · `dynamodb-global-secondary-index` · `dynamodb-item` · `dynamodb-items` · `dynamodb-streams` · `dynamodb-table` · `dynamodb` · `elasticache-cache-node` · `elasticache-for-memcached` · `elasticache-for-redis` · `elasticache` · `keyspaces-managed-apache-cassandra-service` · `neptune` · `quantum-ledger-database-qldb` · `rds-instance` · `rds-mariadb-instance` · `rds-mysql-instance` · `rds-on-vmware` · `rds-oracle-instance` · `rds-postgresql-instance` · `rds-sql-server-instance` · `rds` · `redshift-dense-compute-node` · `redshift-dense-storage-node` · `redshift` · `timestream`

**`aws/devtools/`** (14) — `cloud-development-kit` · `cloud9-resource` · `cloud9` · `cloudshell` · `codeartifact` · `codebuild` · `codecommit` · `codedeploy` · `codepipeline` · `codestar` · `command-line-interface` · `developer-tools` · `tools-and-sdks` · `x-ray`

**`aws/enablement/`** (5) — `customer-enablement` · `iq` · `managed-services` · `professional-services` · `support`

**`aws/enduser/`** (5) — `appstream-2-0` · `desktop-and-app-streaming` · `workdocs` · `worklink` · `workspaces`

**`aws/engagement/`** (5) — `connect` · `customer-engagement` · `pinpoint` · `simple-email-service-ses-email` · `simple-email-service-ses`

**`aws/game/`** (2) — `game-tech` · `gamelift`

**`aws/general/`** (24) — `client` · `disk` · `forums` · `general` · `generic-database` · `generic-firewall` · `generic-office-building` · `generic-saml-token` · `generic-sdk` · `internet-alt1` · `internet-alt2` · `internet-gateway` · `marketplace` · `mobile-client` · `multimedia` · `office-building` · `saml-token` · `sdk` · `ssl-padlock` · `tape-storage` · `toolkit` · `traditional-server` · `user` · `users`

**`aws/integration/`** (23) — `application-integration` · `appsync` · `console-mobile-application` · `event-resource` · `eventbridge-custom-event-bus-resource` · `eventbridge-default-event-bus-resource` · `eventbridge-event` · `eventbridge-pipes` · `eventbridge-rule` · `eventbridge-saas-partner-event-bus-resource` · `eventbridge-scheduler` · `eventbridge-schema` · `eventbridge` · `express-workflows` · `mq` · `simple-notification-service-sns-email-notification` · `simple-notification-service-sns-http-notification` · `simple-notification-service-sns-topic` · `simple-notification-service-sns` · `simple-queue-service-sqs-message` · `simple-queue-service-sqs-queue` · `simple-queue-service-sqs` · `step-functions`

**`aws/iot/`** (61) — `freertos` · `internet-of-things` · `iot-1-click` · `iot-action` · `iot-actuator` · `iot-alexa-echo` · `iot-alexa-enabled-device` · `iot-alexa-skill` · `iot-alexa-voice-service` · `iot-analytics-channel` · `iot-analytics-data-set` · `iot-analytics-data-store` · `iot-analytics-notebook` · `iot-analytics-pipeline` · `iot-analytics` · `iot-bank` · `iot-bicycle` · `iot-button` · `iot-camera` · `iot-car` · `iot-cart` · `iot-certificate` · `iot-coffee-pot` · `iot-core` · `iot-desired-state` · `iot-device-defender` · `iot-device-gateway` · `iot-device-management` · `iot-door-lock` · `iot-events` · `iot-factory` · `iot-fire-tv-stick` · `iot-fire-tv` · `iot-generic` · `iot-greengrass-connector` · `iot-greengrass` · `iot-hardware-board` · `iot-house` · `iot-http` · `iot-http2` · `iot-jobs` · `iot-lambda` · `iot-lightbulb` · `iot-medical-emergency` · `iot-mqtt` · `iot-over-the-air-update` · `iot-policy-emergency` · `iot-policy` · `iot-reported-state` · `iot-rule` · `iot-sensor` · `iot-servo` · `iot-shadow` · `iot-simulator` · `iot-sitewise` · `iot-thermostat` · `iot-things-graph` · `iot-topic` · `iot-travel` · `iot-utility` · `iot-windfarm`

**`aws/management/`** (59) — `amazon-devops-guru` · `amazon-managed-grafana` · `amazon-managed-prometheus` · `amazon-managed-workflows-apache-airflow` · `auto-scaling` · `chatbot` · `cloudformation-change-set` · `cloudformation-stack` · `cloudformation-template` · `cloudformation` · `cloudtrail` · `cloudwatch-alarm` · `cloudwatch-event-event-based` · `cloudwatch-event-time-based` · `cloudwatch-logs` · `cloudwatch-rule` · `cloudwatch` · `codeguru` · `command-line-interface` · `config` · `control-tower` · `license-manager` · `managed-services` · `management-and-governance` · `management-console` · `opsworks-apps` · `opsworks-deployments` · `opsworks-instances` · `opsworks-layers` · `opsworks-monitoring` · `opsworks-permissions` · `opsworks-resources` · `opsworks-stack` · `opsworks` · `organizations-account` · `organizations-organizational-unit` · `organizations` · `personal-health-dashboard` · `proton` · `service-catalog` · `systems-manager-app-config` · `systems-manager-automation` · `systems-manager-documents` · `systems-manager-inventory` · `systems-manager-maintenance-windows` · `systems-manager-opscenter` · `systems-manager-parameter-store` · `systems-manager-patch-manager` · `systems-manager-run-command` · `systems-manager-state-manager` · `systems-manager` · `trusted-advisor-checklist-cost` · `trusted-advisor-checklist-fault-tolerant` · `trusted-advisor-checklist-performance` · `trusted-advisor-checklist-security` · `trusted-advisor-checklist` · `trusted-advisor` · `user-notifications` · `well-architected-tool`

**`aws/media/`** (13) — `elastic-transcoder` · `elemental-conductor` · `elemental-delta` · `elemental-live` · `elemental-mediaconnect` · `elemental-mediaconvert` · `elemental-medialive` · `elemental-mediapackage` · `elemental-mediastore` · `elemental-mediatailor` · `elemental-server` · `kinesis-video-streams` · `media-services`

**`aws/migration/`** (12) — `application-discovery-service` · `cloudendure-migration` · `database-migration-service` · `datasync-agent` · `datasync` · `migration-and-transfer` · `migration-hub` · `server-migration-service` · `snowball-edge` · `snowball` · `snowmobile` · `transfer-for-sftp`

**`aws/ml/`** (31) — `apache-mxnet-on-aws` · `augmented-ai` · `bedrock` · `comprehend` · `deep-learning-amis` · `deep-learning-containers` · `deepcomposer` · `deeplens` · `deepracer` · `elastic-inference` · `forecast` · `fraud-detector` · `kendra` · `lex` · `machine-learning` · `personalize` · `polly` · `q` · `rekognition-image` · `rekognition-video` · `rekognition` · `sagemaker-ground-truth` · `sagemaker-model` · `sagemaker-notebook` · `sagemaker-training-job` · `sagemaker` · `tensorflow-on-aws` · `textract` · `transcribe` · `transform` · `translate`

**`aws/mobile/`** (7) — `amplify` · `api-gateway-endpoint` · `api-gateway` · `appsync` · `device-farm` · `mobile` · `pinpoint`

**`aws/network/`** (40) — `api-gateway-endpoint` · `api-gateway` · `app-mesh` · `client-vpn` · `cloud-map` · `cloudfront-download-distribution` · `cloudfront-edge-location` · `cloudfront-streaming-distribution` · `cloudfront` · `direct-connect` · `elastic-load-balancing` · `elb-application-load-balancer` · `elb-classic-load-balancer` · `elb-network-load-balancer` · `endpoint` · `global-accelerator` · `internet-gateway` · `nacl` · `nat-gateway` · `network-firewall` · `networking-and-content-delivery` · `private-subnet` · `privatelink` · `public-subnet` · `route-53-hosted-zone` · `route-53` · `route-table` · `site-to-site-vpn` · `transit-gateway-attachment` · `transit-gateway` · `vpc-customer-gateway` · `vpc-elastic-network-adapter` · `vpc-elastic-network-interface` · `vpc-flow-logs` · `vpc-peering` · `vpc-router` · `vpc-traffic-mirroring` · `vpc` · `vpn-connection` · `vpn-gateway`

**`aws/quantum/`** (2) — `braket` · `quantum-technologies`

**`aws/robotics/`** (6) — `robomaker-cloud-extension-ros` · `robomaker-development-environment` · `robomaker-fleet-management` · `robomaker-simulator` · `robomaker` · `robotics`

**`aws/satellite/`** (2) — `ground-station` · `satellite`

**`aws/security/`** (40) — `ad-connector` · `artifact` · `certificate-authority` · `certificate-manager` · `cloud-directory` · `cloudhsm` · `cognito` · `detective` · `directory-service` · `firewall-manager` · `guardduty` · `identity-and-access-management-iam-access-analyzer` · `identity-and-access-management-iam-add-on` · `identity-and-access-management-iam-aws-sts-alternate` · `identity-and-access-management-iam-aws-sts` · `identity-and-access-management-iam-data-encryption-key` · `identity-and-access-management-iam-encrypted-data` · `identity-and-access-management-iam-long-term-security-credential` · `identity-and-access-management-iam-mfa-token` · `identity-and-access-management-iam-permissions` · `identity-and-access-management-iam-role` · `identity-and-access-management-iam-temporary-security-credential` · `identity-and-access-management-iam` · `inspector-agent` · `inspector` · `key-management-service` · `macie` · `managed-microsoft-ad` · `resource-access-manager` · `secrets-manager` · `security-hub-finding` · `security-hub` · `security-identity-and-compliance` · `security-lake` · `shield-advanced` · `shield` · `simple-ad` · `single-sign-on` · `waf-filtering-rule` · `waf`

**`aws/storage/`** (31) — `backup` · `cloudendure-disaster-recovery` · `efs-infrequentaccess-primary-bg` · `efs-standard-primary-bg` · `elastic-block-store-ebs-snapshot` · `elastic-block-store-ebs-volume` · `elastic-block-store-ebs` · `elastic-file-system-efs-file-system` · `elastic-file-system-efs` · `fsx-for-lustre` · `fsx-for-windows-file-server` · `fsx` · `multiple-volumes-resource` · `s3-access-points` · `s3-glacier-archive` · `s3-glacier-vault` · `s3-glacier` · `s3-object-lambda-access-points` · `simple-storage-service-s3-bucket-with-objects` · `simple-storage-service-s3-bucket` · `simple-storage-service-s3-object` · `simple-storage-service-s3` · `snow-family-snowball-import-export` · `snowball-edge` · `snowball` · `snowmobile` · `storage-gateway-cached-volume` · `storage-gateway-non-cached-volume` · `storage-gateway-virtual-tape-library` · `storage-gateway` · `storage`

## onprem

**`onprem/analytics/`** (17) — `beam` · `databricks` · `dbt` · `dremio` · `flink` · `hadoop` · `hive` · `metabase` · `norikra` · `powerbi` · `presto` · `singer` · `spark` · `storm` · `superset` · `tableau` · `trino`

**`onprem/client/`** (3) — `client` · `user` · `users`

**`onprem/database/`** (20) — `cassandra` · `clickhouse` · `cockroachdb` · `couchbase` · `couchdb` · `dgraph` · `druid` · `duckdb` · `hbase` · `influxdb` · `janusgraph` · `mariadb` · `mongodb` · `mssql` · `mysql` · `neo4j` · `oracle` · `postgresql` · `qdrant` · `scylla`

**`onprem/monitoring/`** (14) — `cortex` · `datadog` · `dynatrace` · `grafana` · `humio` · `mimir` · `nagios` · `newrelic` · `prometheus-operator` · `prometheus` · `sentry` · `splunk` · `thanos` · `zabbix`

**`onprem/queue/`** (7) — `activemq` · `celery` · `emqx` · `kafka` · `nats` · `rabbitmq` · `zeromq`

**`onprem/workflow/`** (4) — `airflow` · `digdag` · `kubeflow` · `nifi`

## saas

**`saas/analytics/`** (3) — `dataform` · `snowflake` · `stitch`

**`saas/chat/`** (8) — `discord` · `line` · `mattermost` · `messenger` · `rocket-chat` · `slack` · `teams` · `telegram`

**`saas/crm/`** (2) — `intercom` · `zendesk`

**`saas/logging/`** (3) — `datadog` · `newrelic` · `papertrail`

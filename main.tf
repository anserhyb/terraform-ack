provider "alicloud" {
}
variable "k8s_name_prefix" {
  description = "The name prefix used to create managed kubernetes cluster."
  default     = "tf-ack"
}

variable "db_names" {
  type        = list(string)
  default     = ["hermite","cloudserver","lebesgue"]
}

resource "random_uuid" "this" {}
# 默认资源名称。
locals {
  k8s_name     = substr(join("-", [var.k8s_name_prefix, random_uuid.this.result]), 0, 63)
  new_vpc_name = "vpc-for-${local.k8s_name}"
  new_vsw_name = "vsw-for-${local.k8s_name}"
  log_project_name = "log-for-${local.k8s_name}"
}
# 节点ECS实例配置。
data "alicloud_instance_types" "default" {
  cpu_core_count       = 4
  memory_size          = 8
  kubernetes_node_role = "Worker"
}
// 满足实例规格的AZ。
data "alicloud_zones" "default" {
  available_instance_type = data.alicloud_instance_types.default.instance_types[0].id
  available_resource_creation = "KVStore"
}
# 专有网络。
resource "alicloud_vpc" "default" {
  vpc_name   = local.new_vpc_name
  cidr_block = "172.16.0.0/16"
}
# 交换机。
resource "alicloud_vswitch" "vswitches" {
  vswitch_name      = local.new_vsw_name
  vpc_id            = alicloud_vpc.default.id
  cidr_block        = "172.16.0.0/24"
  zone_id = data.alicloud_zones.default.zones[0].id
}
# NAT网关
resource "alicloud_nat_gateway" "default" {
  count  = 1
  vpc_id = alicloud_vpc.default.id
  name   = "tf-nat"
  payment_type = "PayAsYouGo"
  nat_type = "Enhanced"
  vswitch_id = alicloud_vswitch.vswitches.id
}
# EIP
resource "alicloud_eip" "default" {
  count     = 1
  bandwidth = 1
  internet_charge_type = "PayByTraffic"
}

# 绑定EIP
resource "alicloud_eip_association" "default" {
  count         = 1
  allocation_id = alicloud_eip.default[0].id
  instance_id   = alicloud_nat_gateway.default[0].id
}

# 添加SNAT条目
resource "alicloud_snat_entry" "default" {
  count         = 1
  snat_table_id = alicloud_nat_gateway.default[0].snat_table_ids
  source_vswitch_id = join(",", alicloud_vswitch.vswitches.*.id)
  snat_ip = alicloud_eip.default[0].ip_address
}

# RDS
resource "alicloud_db_instance" "default" {
  engine              = "MySQL"
  engine_version      = "8.0"
  vswitch_id          = alicloud_vswitch.vswitches.id
  instance_charge_type = "Postpaid"
  instance_type = "mysql.n2.medium.1"
  security_ips = ["172.16.0.0/16"]
  instance_storage = "20"
}

# 创建RDS用户
resource "alicloud_db_account" "default" {
  instance_id = alicloud_db_instance.default.id
  name        = "tftestnormal"
  account_password    = "Test12345"
}

# 创建RDS数据库
resource "alicloud_db_database" "default" {
  count = 3
  instance_id = alicloud_db_instance.default.id
  name        = var.db_names[count.index]
}

# RDS授权
resource "alicloud_db_account_privilege" "default" {
  instance_id  = alicloud_db_instance.default.id
  account_name = alicloud_db_account.default.name
  privilege    = "ReadWrite"
  db_names     = alicloud_db_database.default.*.name
}

# RDS连接地址
resource "alicloud_db_connection" "connection" {
  instance_id       = alicloud_db_instance.default.id
  connection_prefix = "tf-example"
}

# Redis
resource "alicloud_kvstore_instance" "default" {
  db_instance_name = "tf-test-basic"
  vswitch_id       = alicloud_vswitch.vswitches.id
  security_ips = ["172.16.0.0/16"]
  instance_type  = "Redis"
  engine_version = "5.0"
  payment_type = "PostPaid"
  instance_class    = "redis.basic.small.default"
}

# # MQ
# # resource "alicloud_amqp_instance" "default" {
# #   instance_type  = "professional"
# #   max_tps        = 1000
# #   queue_capacity = 50
# #   support_eip    = false
# #   payment_type   = "Subscription"
# #   period         = 1
# # }

# # 日志服务。
# # resource "alicloud_log_project" "log" {
# #   name        = local.log_project_name
# #   description = "created by terraform for managedkubernetes cluster"
# # }
# Kubernetes托管版。
resource "alicloud_cs_managed_kubernetes" "default" {
  # Kubernetes集群名称。
  name                      = local.k8s_name
  cluster_spec              = "ack.pro.small"
  # 新的Kubernetes集群将位于的vswitch。指定一个或多个vswitch的ID。它必须在availability_zone指定的区域中。
  worker_vswitch_ids        = split(",", join(",", alicloud_vswitch.vswitches.*.id))
  # 是否在创建kubernetes集群时创建新的nat网关。默认为true。
  new_nat_gateway           = false
  # 节点的ECS实例类型。
  worker_instance_types     = [data.alicloud_instance_types.default.instance_types[0].id]
  # Kubernetes集群的总工作节点数。默认值为3。最大限制为50。
  worker_number             = 2
  # ssh登录集群节点的密码。
  password                  = "yt4Y1tiZA9vjKsrX"
  # pod网络的CIDR块。当cluster_network_type设置为flannel，你必须设定该参数。它不能与VPC CIDR相同，并且不能与VPC中的Kubernetes集群使用的CIDR相同，也不能在创建后进行修改。集群中允许的最大主机数量：256。
  pod_cidr                  = "10.0.0.0/16"
  # 服务网络的CIDR块。它不能与VPC CIDR相同，不能与VPC中的Kubernetes集群使用的CIDR相同，也不能在创建后进行修改。
  service_cidr              = "10.1.0.0/20"
  # 是否为kubernetes的节点安装云监控。
  install_cloud_monitor     = true
  # 是否为API Server创建Internet负载均衡。默认为false。
  slb_internet_enabled      = false
  # 节点的系统磁盘类别。其有效值为cloud_ssd和cloud_efficiency。默认为cloud_efficiency。
  worker_disk_category      = "cloud_efficiency"
  
  kube_config           = "~/.kube/config"

  # 节点的数据磁盘类别。其有效值为cloud_ssd和cloud_efficiency，如果未设置，将不会创建数据磁盘。
  # worker_data_disk_category = ""
  # 节点的数据磁盘大小。有效值范围[20〜32768]，以GB为单位。当worker_data_disk_category被呈现，则默认为40。
  # worker_data_disk_size     = 200
  # 日志配置。
  # addons {
  #   name     = "logtail-ds"
  #   config   = "{\"IngressDashboardEnabled\":\"true\",\"sls_project_name\":alicloud_log_project.log.name}"
  # }
  depends_on = [alicloud_snat_entry.default]
}

resource "alicloud_instance" "instance" {
  
  availability_zone = data.alicloud_zones.default.zones[0].id
  security_groups   = [alicloud_cs_managed_kubernetes.default.security_group_id]

  # series III
  instance_type              = data.alicloud_instance_types.default.instance_types[0].id 
  system_disk_category       = "cloud_efficiency"
  image_id                   = "centos_7_9_x64_20G_alibase_20210318.vhd"
  vswitch_id                 = alicloud_vswitch.vswitches.id
  user_data                  = templatefile("user_data.tftpl",
                                        {
                                         kube_config=templatefile("kube_config.tftpl",
                                         {cluster=alicloud_cs_managed_kubernetes.default.id,
                                          server=alicloud_cs_managed_kubernetes.default.connections.api_server_intranet,
                                          certificate-authority-data=alicloud_cs_managed_kubernetes.default.certificate_authority.cluster_cert,
                                          client-certificate-data=alicloud_cs_managed_kubernetes.default.certificate_authority.client_cert,
                                          client-key-data=alicloud_cs_managed_kubernetes.default.certificate_authority.client_key}),
                                         app_yml=file("nginx.yml")
                                        })
  password                   = "passw0RD" 
}

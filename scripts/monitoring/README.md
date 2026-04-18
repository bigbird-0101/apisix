# APISIX Monitoring (Prometheus + Grafana)

Docker Compose 一键部署 Prometheus + Grafana 监控 APISIX。

## 目录结构

```
monitoring/
├── docker-compose.yml
├── prometheus.yml
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/prometheus.yml   # 自动注入 Prometheus 数据源
│   │   └── dashboards/dashboards.yml    # 自动加载 dashboards 目录
│   └── dashboards/                       # 放 *.json dashboard 文件
└── README.md
```

## 部署步骤

### 1. 在 APISIX 每个节点启用 prometheus 插件

编辑 `/usr/local/apisix/conf/config.yaml`，确保 prometheus 插件启用并暴露端口：

```yaml
plugins:
  - prometheus  # 确保包含

plugin_attr:
  prometheus:
    export_uri: /apisix/prometheus/metrics
    metric_prefix: apisix_
    enable_export_server: true
    export_addr:
      ip: 0.0.0.0
      port: 9091
```

然后 reload：

```bash
apisix reload
```

测试是否生效：

```bash
curl http://localhost:9091/apisix/prometheus/metrics | head -20
```

### 2. 给每条路由启用 prometheus 插件

通过 Admin API 给路由加上 `prometheus` 插件（或用全局规则统一配置）：

```bash
# 方式 A：给单条路由加
curl -X PATCH "http://127.0.0.1:9180/apisix/admin/routes/openclaw-codex" \
  -H "X-API-KEY: $admin_key" \
  -d '{"plugins": {"prometheus": {}}}'

# 方式 B：全局规则（所有路由都生效）
curl -X PUT "http://127.0.0.1:9180/apisix/admin/global_rules/1" \
  -H "X-API-KEY: $admin_key" \
  -d '{"plugins": {"prometheus": {}}}'
```

### 3. 修改 prometheus.yml

编辑 `prometheus.yml`，把 `targets` 改成你的 APISIX 节点 IP：

```yaml
- targets:
    - "10.168.0.6:9091"
    - "10.168.0.7:9091"
    - "10.168.0.8:9091"
```

### 4. 启动 Prometheus + Grafana

```bash
cd /path/to/scripts/monitoring
docker-compose up -d
```

### 5. 访问

- **Prometheus**: http://服务器IP:9090
- **Grafana**: http://服务器IP:3000 （默认账号 `admin` / `admin`）

## 验证

在 Prometheus 里查 `apisix_http_status` 或 `apisix_http_requests_total`，应该能看到数据。

## 导入 APISIX 官方 Grafana Dashboard

Grafana 启动后，登录控制台：

1. 左侧菜单 → **Dashboards** → **New** → **Import**
2. 输入 dashboard ID: **11719**（APISIX 官方 dashboard）
3. 数据源选 Prometheus
4. 导入即可

或者把 dashboard JSON 放到 `grafana/dashboards/` 目录下，重启 grafana 自动加载。

## 常用指标

| 指标 | 含义 |
|------|------|
| `apisix_http_requests_total` | 请求总数（按 status, route, service 分类） |
| `apisix_http_latency` | 请求延迟（histogram） |
| `apisix_bandwidth` | 带宽（ingress/egress） |
| `apisix_nginx_http_current_connections` | 当前连接数 |
| `apisix_etcd_reachable` | etcd 可达性 |
| `apisix_batch_process_entries` | 批处理队列长度 |

## 停止

```bash
docker-compose down          # 停止容器
docker-compose down -v       # 停止并删除数据卷（会清空历史数据）
```

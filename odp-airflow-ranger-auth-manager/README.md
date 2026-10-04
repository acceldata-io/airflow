# odp-airflow-ranger-auth-manager

ODP auth manager for Apache Airflow 3.2.x. Authentication stays with
`FabAuthManager`; DAG authorization is decided by the colocated Ranger
authz agent at `http://127.0.0.1:9183`.

This is not `apache-airflow-providers-apache-ranger` and is not an
upstream Airflow provider.

```ini
[core]
auth_manager = odp_airflow_ranger_auth_manager.RangerAuthManager

[ranger]
agent_url = http://127.0.0.1:9183
token_file = /etc/airflow/ranger-authz-agent.token
connect_timeout = 0.2
read_timeout = 2.0
```

M1 overrides `is_authorized_dag` only. Every other `is_authorized_*`
method still uses FAB.

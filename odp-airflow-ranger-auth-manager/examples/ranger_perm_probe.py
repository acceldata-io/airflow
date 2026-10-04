"""Ranger permission probe for Airflow 3.2.

dag_id: ranger_perm_probe

Copy this file into the DAGs folder used by dag-processor (and scheduler /
api-server if they do not share that volume). Trigger one run, then exercise
the UI or API actions below. Each action is a Ranger access type on resource
``dag = ranger_perm_probe`` in service ``odp_airflow``.

This only hits Ranger for DAG authorization (M1). Connections, variables,
pools, configs, and views still go through FAB.

How to test
-----------
Start from an allow-all policy for your user on ``dag = *`` (the lab already
has that for ``salmon`` / ``rangerpoc``). Then add a **deny** for one access
type at a time and confirm that one button/API fails while the others work.

  DAG page / graph          GET dag                 read
  Edit DAG / params         PUT dag                 edit
  Delete DAG                DELETE dag              delete
  Trigger run               POST dag RUN            trigger
  Open a run                GET dag RUN             read_run
  Mark success / fail       PUT dag RUN             edit_run
  Delete a run              DELETE dag RUN          delete_run
  Task in the graph         GET dag TASK            read_task
  Task instance list        GET dag TASK_INSTANCE   read_task_instance
  Clear task                PUT/DELETE TASK_INSTANCE clear_task
  Task log                  GET dag TASK_LOGS       read_logs
  Code view                 GET dag CODE            read_code
  XCom tab                  GET dag XCOM            read_xcom
  Audit log for this DAG    GET dag AUDIT_LOG       read_audit_log
  Graph / dependencies      GET dag DEPENDENCIES    read_dependencies
  Import warnings           GET dag WARNING         read_warning
  DAG version history       GET dag VERSION         read_version
  HITL approval page        GET dag HITL_DETAIL     read_hitl
  Submit HITL response      POST/PUT HITL_DETAIL    respond_hitl

``testdag`` is already denied in the lab. Use this dag_id instead.
"""

from __future__ import annotations

from datetime import timedelta

import pendulum

from airflow.providers.standard.operators.hitl import HITLOperator
from airflow.sdk import dag, task


@dag(
    dag_id="ranger_perm_probe",
    start_date=pendulum.datetime(2026, 1, 1, tz="UTC"),
    schedule=None,
    catchup=False,
    tags=["ranger", "poc"],
    params={"note": "edit this param and save to create a new DAG version"},
    doc_md=(
        "Permission probe for Ranger DAG access types. Trigger a run, open "
        "logs / XCom / task instances, then answer or wait out the HITL step."
    ),
)
def ranger_perm_probe():
    @task
    def emit_logs() -> dict:
        import logging

        log = logging.getLogger("airflow.task")
        log.info("ranger_perm_probe: use this line to test read_logs")
        print("stdout is also in the task log")
        return {"probe": "xcom-value", "n": 3}

    @task
    def items() -> list[str]:
        return ["alpha", "beta", "gamma"]

    @task
    def mapped_step(name: str, payload: dict) -> str:
        print(f"mapped_step name={name} payload={payload}")
        return f"{name}:{payload['n']}"

    @task
    def gather(parts: list[str]) -> str:
        print("gathered", parts)
        return "|".join(parts)

    payload = emit_logs()
    mapped = mapped_step.partial(payload=payload).expand(name=items())
    collected = gather(mapped)

    approve = HITLOperator(
        task_id="approve_continue",
        subject="Ranger HITL probe — approve to finish the run",
        body=(
            "Exercises read_hitl and respond_hitl. "
            "If nobody answers, it auto-approves after 45 seconds."
        ),
        options=["approve", "reject"],
        defaults=["approve"],
        execution_timeout=timedelta(seconds=45),
    )
    collected >> approve


ranger_perm_probe()

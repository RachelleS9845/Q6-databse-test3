# Question 6 — Monthly Payroll Processing

**Script:** [`q06_payroll.sql`](q06_payroll.sql) · **Schema:** `q06_payroll` · **DBMS:** PostgreSQL 14+ with pg_cron

## How to run

pgAdmin: open the Query Tool, open `q06_payroll.sql` and press **F5**. Results appear in *Data Output*; the test messages (`RAISE NOTICE`) appear in *Messages*.

```bash
psql -d ict371 -f q06_payroll.sql
```

The script drops and recreates the `q06_payroll` schema, so it can be run as many times as you like. Part (g) needs pg_cron (setup steps are in the [main README](../README.md#setting-up-pg_cron-part-g)).

## What each part does

| Part | Object | How it meets the requirement |
|------|--------|------------------------------|
| (a) Database & seed [6] | `employees`, `payroll`, `salary_audit` | Money columns `>= 0`, `active BOOLEAN`. `pay_month` must be a month start (`CHECK (pay_month = date_trunc('month', pay_month)::date)`), with `UNIQUE (employee_id, pay_month)`. Seed: 4 active and 1 inactive employee. Payroll is run for **two months**, and Peter becomes inactive between them. |
| (b) Function [6] | `fn_net_pay(p_employee_id)` | `basic_salary + allowance − deduction`. Raises an error for an unknown employee or a negative result. |
| (c) Procedure [8] | `pr_process_payroll(p_month)` | Rejects a date that is not the 1st of a month. Uses a **query FOR loop** over active employees, calls `fn_net_pay`, and does `INSERT … ON CONFLICT DO NOTHING`, so missing rows are added and existing rows are left untouched. If any employee's calculation raises an error, the whole `CALL` rolls back. The test adds a bad employee inside a transaction and shows **0** rows were inserted, not 3. |
| (d) Trigger [8] | `trg_employees_salary_audit` (AFTER UPDATE OF basic_salary) | `WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)`. A real raise is logged. Setting the same salary, or changing the allowance, is not. |
| (e) View [5] | `v_payroll_report` | `payroll JOIN employees` with **no** `active` filter, so Peter's earlier payslip still appears after he leaves. |
| (f) Index [5] | `idx_payroll_pay_month (pay_month)` | The existing unique index leads with `employee_id`, so it can't jump to all rows for one month. This index leads with `pay_month` and does not duplicate it. `pg_indexes` lists both side by side. |
| (g) Job [6] | cron `0 2 1 * *` | Runs at 02:00 on the 1st of each month with `(date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date`. Inspect the job in `cron.job` and its run history in `cron.job_run_details`; both queries are in the script. |

## Expected results (verified on PostgreSQL 16)

Month 1 has 4 rows, month 2 has 3. A rerun after a salary rise inserts 0 new rows and the old gross of K11 000 is kept. `salary_audit` has exactly one row. The invalid-employee test leaves 0 rows for the month.

Dates are written relative to `CURRENT_DATE`, so the views and summaries show data whenever the script is run.

## Tip: getting a run-history screenshot without waiting a month

The real job only runs on the 1st of the month, so `cron.job_run_details` starts empty. To show history, run a one-minute copy, wait about a minute, query it, then remove it:

```sql
SELECT cron.schedule('q06_payroll_demo', '* * * * *',
  $$CALL q06_payroll.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);
-- wait about 60 seconds
SELECT d.runid, d.status, d.return_message, d.start_time
FROM cron.job_run_details d JOIN cron.job j USING (jobid)
WHERE j.jobname = 'q06_payroll_demo' ORDER BY d.start_time DESC;
SELECT cron.unschedule('q06_payroll_demo');
```

The demo is safe to run because the procedure leaves existing payroll rows unchanged.

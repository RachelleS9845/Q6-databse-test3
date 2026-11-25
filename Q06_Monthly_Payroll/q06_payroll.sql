/* =====================================================================
   ICT371 Advanced Database — Question 6: Monthly Payroll Processing
   DBMS : PostgreSQL 14+ (tested on PostgreSQL 16) with pg_cron
   Model: gross = basic_salary + allowance ; net = gross - deduction.
          Existing payroll rows are kept unchanged when a month is rerun.
   ===================================================================== */

DROP SCHEMA IF EXISTS q06_payroll CASCADE;
CREATE SCHEMA q06_payroll;
SET search_path TO q06_payroll, public;

/* ---------------------------------------------------------------------
   (a) DATABASE — tables  [6 marks]
   --------------------------------------------------------------------- */
CREATE TABLE employees (
    employee_id   SERIAL        PRIMARY KEY,
    full_name     VARCHAR(100)  NOT NULL,
    basic_salary  NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance     NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (allowance >= 0),
    deduction     NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deduction >= 0),
    active        BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id   SERIAL        PRIMARY KEY,
    employee_id  INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month    DATE          NOT NULL
        CONSTRAINT chk_pay_month_first_day CHECK (pay_month = date_trunc('month', pay_month)::date),
    gross_pay    NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay      NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id     SERIAL        PRIMARY KEY,
    employee_id  INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary   NUMERIC(12,2) NOT NULL,
    new_salary   NUMERIC(12,2) NOT NULL,
    changed_at   TIMESTAMPTZ   NOT NULL DEFAULT now()
);

/* ---------------------------------------------------------------------
   (b) FUNCTION fn_net_pay(p_employee_id)  [6 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
SET search_path = q06_payroll, public
AS $$
DECLARE
    v_emp employees%ROWTYPE;
    v_net NUMERIC(12,2);
BEGIN
    SELECT * INTO v_emp FROM employees WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Employee % does not exist', p_employee_id USING ERRCODE = 'P0002';
    END IF;

    v_net := v_emp.basic_salary + v_emp.allowance - v_emp.deduction;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Employee % has a negative net pay (K%): deduction exceeds gross pay',
                        p_employee_id, v_net USING ERRCODE = 'P0001';
    END IF;

    RETURN v_net;
END;
$$;

/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_process_payroll(p_month)  [8 marks]
   - p_month must be the first day of a month
   - query FOR loop over ACTIVE employees
   - ON CONFLICT DO NOTHING: missing rows are inserted, existing rows are
     left exactly as they were
   - if fn_net_pay raises for ANY employee the whole CALL is rolled back,
     so no partial payroll is left behind
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
SET search_path = q06_payroll, public
AS $$
DECLARE
    r_emp      RECORD;
    v_net      NUMERIC(12,2);
    v_inserted INTEGER := 0;
    v_rows     INTEGER;
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'Payroll rejected: % is not the first day of a month', p_month
              USING ERRCODE = '22023';
    END IF;

    FOR r_emp IN
        SELECT employee_id, basic_salary, allowance
        FROM   employees
        WHERE  active = TRUE
        ORDER  BY employee_id
    LOOP
        v_net := fn_net_pay(r_emp.employee_id);      -- raises on an invalid calculation

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r_emp.employee_id, p_month, r_emp.basic_salary + r_emp.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_inserted := v_inserted + v_rows;
    END LOOP;

    RAISE NOTICE 'Payroll for %: % new row(s) inserted', to_char(p_month, 'Mon YYYY'), v_inserted;
END;
$$;

/* ---------------------------------------------------------------------
   (d) TRIGGER — AFTER UPDATE: audit real basic_salary changes  [8 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q06_payroll, public
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

/* ---------------------------------------------------------------------
   (a) SEED DATA — active + inactive employees, payroll for TWO months
   Month 1 = two months ago, Month 2 = last month (always month-start dates).
   Peter is active in month 1, then leaves (inactive) before month 2.
   --------------------------------------------------------------------- */
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Mwila Banda',    9500.00, 1500.00, 1200.00, TRUE),
    ('Chanda Phiri',   7200.00, 1000.00,  900.00, TRUE),
    ('Natasha Zulu',  12000.00, 2500.00, 2100.00, TRUE),
    ('Peter Mumba',    6000.00,  800.00,  650.00, TRUE),
    ('Grace Lungu',    5000.00,  500.00,  400.00, FALSE);   -- inactive from the start

CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date);  -- 4 rows

UPDATE employees SET active = FALSE WHERE full_name = 'Peter Mumba';                        -- Peter leaves

CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date);   -- 3 rows

SELECT * FROM payroll ORDER BY pay_month, employee_id;

/* ---------------------------------------------------------------------
   TESTS for (b), (c), (d)
   --------------------------------------------------------------------- */
SELECT employee_id, full_name, fn_net_pay(employee_id) AS net_pay_now FROM employees ORDER BY 1;

DO $$
BEGIN
    BEGIN PERFORM fn_net_pay(99);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_net_pay(99)  -> %', SQLERRM; END;
    BEGIN CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) + INTERVAL '14 days')::date); -- the 15th
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Mid-month date  -> %', SQLERRM; END;
END $$;

-- (c) rerun last month after a salary rise: existing rows stay UNCHANGED
UPDATE employees SET basic_salary = 10000.00 WHERE full_name = 'Mwila Banda';   -- (d) audited
UPDATE employees SET basic_salary = 7200.00  WHERE full_name = 'Chanda Phiri';  -- same value: NOT audited
UPDATE employees SET allowance    = 1100.00  WHERE full_name = 'Chanda Phiri';  -- not salary: NOT audited
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date);   -- 0 new rows
SELECT * FROM payroll WHERE employee_id = 1 ORDER BY pay_month;                 -- old gross 11000 kept
SELECT * FROM salary_audit ORDER BY audit_id;                                   -- exactly one row

-- (c) an invalid employee makes the WHOLE call fail (nothing inserted for anyone)
BEGIN;
INSERT INTO employees (full_name, basic_salary, allowance, deduction)
VALUES ('Test Overdeducted', 1000.00, 0, 5000.00);                 -- net would be -4000
DO $$
BEGIN
    CALL q06_payroll.pr_process_payroll(date_trunc('month', CURRENT_DATE)::date);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Whole call failed -> %', SQLERRM;
END $$;
SELECT COUNT(*) AS rows_for_this_month FROM payroll
WHERE pay_month = date_trunc('month', CURRENT_DATE)::date;          -- 0, not 3
ROLLBACK;                                                            -- remove the test employee

/* ---------------------------------------------------------------------
   (e) VIEW v_payroll_report — includes history of now-inactive staff  [5 marks]
   Plain JOIN with NO "active" filter, so Peter's old payslip still shows.
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id,
       e.full_name,
       e.active AS currently_active,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM   payroll p
JOIN   employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;

/* ---------------------------------------------------------------------
   (f) INDEX — report filtered by pay_month across all employees  [5 marks]
   Justification: the UNIQUE(employee_id, pay_month) index leads with
   employee_id, so it cannot jump straight to "all rows for one month".
   A separate single-column index on pay_month serves that report and does
   not duplicate the existing unique index (different leading column).
   --------------------------------------------------------------------- */
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM   payroll
WHERE  pay_month = (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date;

BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN ANALYZE
SELECT employee_id, gross_pay, net_pay
FROM   payroll
WHERE  pay_month = (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date;
COMMIT;

-- the two indexes side by side (no duplication)
SELECT indexname, indexdef FROM pg_indexes
WHERE schemaname = 'q06_payroll' AND tablename = 'payroll';

/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB — 02:00 on day 1 of each month, for the PREVIOUS month  [6 marks]
   --------------------------------------------------------------------- */
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q06_monthly_payroll',
    '0 2 1 * *',                                   -- 02:00 on the 1st of every month
    $$CALL q06_payroll.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$
);

-- Inspect the job
SELECT jobid, jobname, schedule, command, database, username, active
FROM   cron.job
WHERE  jobname = 'q06_monthly_payroll';

-- Inspect its run history (empty until the first scheduled run happens)
SELECT d.runid, d.status, d.return_message, d.start_time, d.end_time
FROM   cron.job_run_details d
JOIN   cron.job j ON j.jobid = d.jobid
WHERE  j.jobname = 'q06_monthly_payroll'
ORDER  BY d.start_time DESC
LIMIT  10;

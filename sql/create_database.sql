-- IV1351 Project, Task 1: create database
-- Course layout and teaching load allocation (PostgreSQL)

DROP TABLE IF EXISTS
    allocation, employee_skill, skill, salary, employee, department,
    job_title, person, planned_activity, derived_activity_formula,
    teaching_activity, course_instance, course_layout, course,
    study_period, business_rule
CASCADE;
DROP FUNCTION IF EXISTS check_max_course_instances();

-- Constants and rules -------------------------------------------------

CREATE TABLE business_rule (
    business_rule_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_name        VARCHAR(100) NOT NULL UNIQUE,
    rule_value       INT          NOT NULL
);

CREATE TABLE study_period (
    study_period_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    period_name     VARCHAR(10) NOT NULL UNIQUE,
    start_month     SMALLINT    NOT NULL CHECK (start_month BETWEEN 1 AND 12),
    end_month       SMALLINT    NOT NULL CHECK (end_month BETWEEN 1 AND 12),
    CHECK (start_month <= end_month)
);

-- Courses ----------------------------------------------------------------

CREATE TABLE course (
    course_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_code VARCHAR(10) NOT NULL UNIQUE
);

-- One row per version of a course layout
CREATE TABLE course_layout (
    course_layout_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id        INT          NOT NULL REFERENCES course (course_id),
    course_name      VARCHAR(200) NOT NULL,
    hp               NUMERIC(4,1) NOT NULL CHECK (hp > 0),
    min_students     INT          NOT NULL CHECK (min_students >= 0),
    max_students     INT          NOT NULL,
    valid_from       DATE         NOT NULL,
    CHECK (max_students >= min_students),
    UNIQUE (course_id, valid_from)
);

CREATE TABLE course_instance (
    course_instance_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    instance_code      VARCHAR(20) NOT NULL UNIQUE,
    course_layout_id   INT         NOT NULL REFERENCES course_layout (course_layout_id),
    study_year         SMALLINT    NOT NULL,
    study_period_id    INT         NOT NULL REFERENCES study_period (study_period_id),
    num_students       INT         NOT NULL CHECK (num_students >= 0)
);

-- Teaching activities -------------------------------------------------

CREATE TABLE teaching_activity (
    teaching_activity_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    activity_name        VARCHAR(50)  NOT NULL UNIQUE,
    factor               NUMERIC(4,2) NOT NULL DEFAULT 1 CHECK (factor > 0)
);

-- Coefficients for derived activities (examination, administration):
-- hours = base_hours + hours_per_hp * hp + hours_per_student * num_students
CREATE TABLE derived_activity_formula (
    teaching_activity_id INT PRIMARY KEY
                         REFERENCES teaching_activity (teaching_activity_id),
    base_hours           NUMERIC(8,3) NOT NULL DEFAULT 0,
    hours_per_hp         NUMERIC(8,3) NOT NULL DEFAULT 0,
    hours_per_student    NUMERIC(8,3) NOT NULL DEFAULT 0
);

-- planned_hours is NULL for derived activities, whose hours are
-- calculated from derived_activity_formula
CREATE TABLE planned_activity (
    course_instance_id   INT NOT NULL
                         REFERENCES course_instance (course_instance_id) ON DELETE CASCADE,
    teaching_activity_id INT NOT NULL
                         REFERENCES teaching_activity (teaching_activity_id),
    planned_hours        NUMERIC(7,2) CHECK (planned_hours >= 0),
    PRIMARY KEY (course_instance_id, teaching_activity_id)
);

-- Persons and employees -------------------------------------------------

CREATE TABLE person (
    person_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    personal_number VARCHAR(12)  NOT NULL UNIQUE,
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100) NOT NULL,
    phone_number    VARCHAR(20)  NOT NULL,
    address         VARCHAR(500) NOT NULL
);

CREATE TABLE job_title (
    job_title_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_title    VARCHAR(100) NOT NULL UNIQUE
);

-- manager_id gets its FK after employee is created (circular reference)
CREATE TABLE department (
    department_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    department_name VARCHAR(100) NOT NULL UNIQUE,
    manager_id      INT
);

CREATE TABLE employee (
    employee_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employment_number VARCHAR(20) NOT NULL UNIQUE,
    person_id         INT NOT NULL UNIQUE REFERENCES person (person_id),
    department_id     INT NOT NULL REFERENCES department (department_id),
    job_title_id      INT NOT NULL REFERENCES job_title (job_title_id),
    supervisor_id     INT REFERENCES employee (employee_id) ON DELETE SET NULL
);

ALTER TABLE department
    ADD CONSTRAINT fk_department_manager
    FOREIGN KEY (manager_id) REFERENCES employee (employee_id) ON DELETE SET NULL;

-- Salary history, one row per salary change
CREATE TABLE salary (
    employee_id    INT           NOT NULL REFERENCES employee (employee_id) ON DELETE CASCADE,
    valid_from     DATE          NOT NULL,
    monthly_salary NUMERIC(10,2) NOT NULL CHECK (monthly_salary > 0),
    PRIMARY KEY (employee_id, valid_from)
);

CREATE TABLE skill (
    skill_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    skill_name VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE employee_skill (
    employee_id INT NOT NULL REFERENCES employee (employee_id) ON DELETE CASCADE,
    skill_id    INT NOT NULL REFERENCES skill (skill_id) ON DELETE CASCADE,
    PRIMARY KEY (employee_id, skill_id)
);

-- Allocations -----------------------------------------------------------

-- allocated_hours are stored without multiplication factor
CREATE TABLE allocation (
    employee_id          INT          NOT NULL REFERENCES employee (employee_id),
    course_instance_id   INT          NOT NULL,
    teaching_activity_id INT          NOT NULL,
    allocated_hours      NUMERIC(7,2) NOT NULL CHECK (allocated_hours > 0),
    PRIMARY KEY (employee_id, course_instance_id, teaching_activity_id),
    FOREIGN KEY (course_instance_id, teaching_activity_id)
        REFERENCES planned_activity (course_instance_id, teaching_activity_id)
        ON DELETE CASCADE
);

-- Business rule: a teacher must not be allocated to more than
-- 'max_course_instances_per_period' different course instances
-- in the same period of the same year
CREATE FUNCTION check_max_course_instances() RETURNS TRIGGER AS $$
DECLARE
    v_year   SMALLINT;
    v_period INT;
    v_limit  INT;
    v_count  INT;
BEGIN
    SELECT study_year, study_period_id INTO v_year, v_period
    FROM course_instance
    WHERE course_instance_id = NEW.course_instance_id;

    SELECT rule_value INTO v_limit
    FROM business_rule
    WHERE rule_name = 'max_course_instances_per_period';

    IF v_limit IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT COUNT(DISTINCT ci.course_instance_id) INTO v_count
    FROM allocation a
    JOIN course_instance ci ON ci.course_instance_id = a.course_instance_id
    WHERE a.employee_id = NEW.employee_id
      AND ci.study_year = v_year
      AND ci.study_period_id = v_period
      AND ci.course_instance_id <> NEW.course_instance_id;

    IF v_count + 1 > v_limit THEN
        RAISE EXCEPTION 'Employee % would exceed % course instances in period % of %',
            NEW.employee_id, v_limit, v_period, v_year;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_max_course_instances
    BEFORE INSERT OR UPDATE ON allocation
    FOR EACH ROW EXECUTE FUNCTION check_max_course_instances();

-- IV1351 Data Storage Paradigms, project task 1
-- Creates the course layout and teaching load allocation database (PostgreSQL).

DROP TABLE IF EXISTS allocation, planned_activity, course_instance, course_layout,
    workload_formula, teaching_activity, study_period, employee_skill, skill,
    employee_salary, person_phone, person_email, business_rule CASCADE;
ALTER TABLE IF EXISTS department DROP CONSTRAINT IF EXISTS fk_department_manager;
DROP TABLE IF EXISTS employee, department, job_title, person CASCADE;
DROP FUNCTION IF EXISTS check_max_course_instances() CASCADE;

-- ---------------------------------------------------------------------------
-- Constants and lookup tables
-- ---------------------------------------------------------------------------

-- Named numeric constants used by business rules, e.g. the max number of
-- course instances a teacher may be allocated to in one period.
CREATE TABLE business_rule (
    business_rule_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_name        VARCHAR(100) NOT NULL UNIQUE,
    rule_value       NUMERIC(10,3) NOT NULL
);

CREATE TABLE study_period (
    study_period_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    period_name     VARCHAR(10) NOT NULL UNIQUE
);

CREATE TABLE job_title (
    job_title_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_title    VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE skill (
    skill_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    skill_name VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE teaching_activity (
    teaching_activity_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    activity_name        VARCHAR(100) NOT NULL UNIQUE,
    factor               NUMERIC(5,2) NOT NULL CHECK (factor > 0)
);

-- Coefficients for activities whose hours are derived per course instance:
-- hours = base_hours + hours_per_hp * hp + hours_per_student * num_students
CREATE TABLE workload_formula (
    teaching_activity_id INT PRIMARY KEY
        REFERENCES teaching_activity (teaching_activity_id) ON DELETE CASCADE,
    base_hours           NUMERIC(8,3) NOT NULL,
    hours_per_hp         NUMERIC(8,3) NOT NULL,
    hours_per_student    NUMERIC(8,3) NOT NULL
);

-- ---------------------------------------------------------------------------
-- People and organisation
-- ---------------------------------------------------------------------------

CREATE TABLE person (
    person_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    personal_number VARCHAR(12)  NOT NULL UNIQUE,
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100) NOT NULL,
    street          VARCHAR(200) NOT NULL,
    zip             VARCHAR(10)  NOT NULL,
    city            VARCHAR(100) NOT NULL
);

CREATE TABLE person_phone (
    person_id    INT NOT NULL REFERENCES person (person_id) ON DELETE CASCADE,
    phone_number VARCHAR(20) NOT NULL,
    PRIMARY KEY (person_id, phone_number)
);

CREATE TABLE person_email (
    person_id INT NOT NULL REFERENCES person (person_id) ON DELETE CASCADE,
    email     VARCHAR(200) NOT NULL,
    PRIMARY KEY (person_id, email)
);

-- manager_id is added after employee exists (circular reference).
CREATE TABLE department (
    department_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    department_name VARCHAR(100) NOT NULL UNIQUE,
    manager_id      INT
);

CREATE TABLE employee (
    employee_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employment_id VARCHAR(20) NOT NULL UNIQUE,
    person_id     INT NOT NULL UNIQUE REFERENCES person (person_id),
    department_id INT NOT NULL REFERENCES department (department_id),
    job_title_id  INT NOT NULL REFERENCES job_title (job_title_id),
    supervisor_id INT REFERENCES employee (employee_id)
);

ALTER TABLE department
    ADD CONSTRAINT fk_department_manager
    FOREIGN KEY (manager_id) REFERENCES employee (employee_id) ON DELETE SET NULL;

-- Salary history. The salary valid at a date is the row with the latest
-- valid_from that is not after that date.
CREATE TABLE employee_salary (
    employee_id    INT NOT NULL REFERENCES employee (employee_id) ON DELETE CASCADE,
    valid_from     DATE NOT NULL,
    monthly_salary NUMERIC(10,2) NOT NULL CHECK (monthly_salary >= 0),
    PRIMARY KEY (employee_id, valid_from)
);

CREATE TABLE employee_skill (
    employee_id INT NOT NULL REFERENCES employee (employee_id) ON DELETE CASCADE,
    skill_id    INT NOT NULL REFERENCES skill (skill_id),
    PRIMARY KEY (employee_id, skill_id)
);

-- ---------------------------------------------------------------------------
-- Courses
-- ---------------------------------------------------------------------------

-- A course layout is versioned. A change (e.g. new hp) adds a new row with a
-- higher version, older course instances keep pointing at the old row.
CREATE TABLE course_layout (
    course_layout_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_code      VARCHAR(10)  NOT NULL,
    version          INT          NOT NULL CHECK (version >= 1),
    course_name      VARCHAR(200) NOT NULL,
    hp               NUMERIC(4,1) NOT NULL CHECK (hp > 0),
    min_students     INT          NOT NULL CHECK (min_students >= 0),
    max_students     INT          NOT NULL,
    UNIQUE (course_code, version),
    CHECK (max_students >= min_students)
);

CREATE TABLE course_instance (
    course_instance_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    instance_code      VARCHAR(20) NOT NULL UNIQUE,
    course_layout_id   INT NOT NULL REFERENCES course_layout (course_layout_id),
    study_year         INT NOT NULL CHECK (study_year BETWEEN 2000 AND 2100),
    study_period_id    INT NOT NULL REFERENCES study_period (study_period_id),
    num_students       INT NOT NULL CHECK (num_students >= 0)
);

-- planned_hours is NULL for activities with a workload_formula (examination,
-- administration), their hours are computed from num_students and hp.
CREATE TABLE planned_activity (
    course_instance_id   INT NOT NULL
        REFERENCES course_instance (course_instance_id) ON DELETE CASCADE,
    teaching_activity_id INT NOT NULL
        REFERENCES teaching_activity (teaching_activity_id),
    planned_hours        NUMERIC(7,1) CHECK (planned_hours >= 0),
    PRIMARY KEY (course_instance_id, teaching_activity_id)
);

CREATE TABLE allocation (
    employee_id          INT NOT NULL REFERENCES employee (employee_id),
    course_instance_id   INT NOT NULL,
    teaching_activity_id INT NOT NULL,
    allocated_hours      NUMERIC(7,1) NOT NULL CHECK (allocated_hours >= 0),
    PRIMARY KEY (employee_id, course_instance_id, teaching_activity_id),
    FOREIGN KEY (course_instance_id, teaching_activity_id)
        REFERENCES planned_activity (course_instance_id, teaching_activity_id)
        ON DELETE CASCADE
);

-- ---------------------------------------------------------------------------
-- Business rule: a teacher may not be allocated to more than
-- 'max_course_instances_per_period' different course instances in the same
-- study period of the same year.
-- ---------------------------------------------------------------------------

CREATE FUNCTION check_max_course_instances() RETURNS TRIGGER AS $$
DECLARE
    max_instances INT;
    num_instances INT;
BEGIN
    SELECT rule_value INTO max_instances
    FROM business_rule WHERE rule_name = 'max_course_instances_per_period';

    SELECT COUNT(DISTINCT a.course_instance_id) INTO num_instances
    FROM allocation a
    JOIN course_instance ci ON ci.course_instance_id = a.course_instance_id
    JOIN course_instance new_ci ON new_ci.course_instance_id = NEW.course_instance_id
    WHERE a.employee_id = NEW.employee_id
      AND ci.study_year = new_ci.study_year
      AND ci.study_period_id = new_ci.study_period_id;

    IF num_instances > max_instances THEN
        RAISE EXCEPTION 'Employee % would be allocated to % course instances in one period, max is %',
            NEW.employee_id, num_instances, max_instances;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_max_course_instances
    AFTER INSERT OR UPDATE ON allocation
    FOR EACH ROW EXECUTE FUNCTION check_max_course_instances();

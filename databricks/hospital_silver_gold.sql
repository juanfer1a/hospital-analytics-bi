-- Databricks notebook source
-- MAGIC %md
-- MAGIC # Hospital – Arquitectura Medallón: Plata y Oro
-- MAGIC
-- MAGIC | Capa | Ubicación | Tipo de objeto | Propósito |
-- MAGIC |---|---|---|---|
-- MAGIC | Bronce | `bi.hospital` | Tablas originales (Kaggle) | Datos tal como llegaron |
-- MAGIC | Plata | `bi.hospital_silver` | Tablas Delta (CTAS) | Datos limpios, tipados, estandarizados y auditables |
-- MAGIC | Oro | `bi.hospital_gold` | Vistas | Modelo constelación (4 hechos + 7 dimensiones) listo para Power BI |
-- MAGIC
-- MAGIC **Orden de ejecución:** de arriba hacia abajo. Plata depende de bronce y oro depende de plata.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 0. Esquemas

-- COMMAND ----------

CREATE SCHEMA IF NOT EXISTS bi.hospital_silver COMMENT 'Capa plata: datos limpios del hospital';
CREATE SCHEMA IF NOT EXISTS bi.hospital_gold   COMMENT 'Capa oro: modelo dimensional del hospital';

-- COMMAND ----------

-- MAGIC %md
-- MAGIC # CAPA PLATA
-- MAGIC Reglas generales aplicadas a todas las tablas:
-- MAGIC - Nombres de columnas en `snake_case` y corregidos (`appoIntment_Id` → `appointment_id`, `admisson_ID` → `admission_id`).
-- MAGIC - `TRIM` en textos y tipos correctos (`timestamp` a medianoche → `DATE`, montos → `DECIMAL(12,2)`).
-- MAGIC - Deduplicación defensiva por llave primaria con `QUALIFY ROW_NUMBER()`.
-- MAGIC - Columna de auditoría `dwh_load_date`.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### 1.1 Departamentos, pabellones, habitaciones y camas (estructura física)

-- COMMAND ----------

CREATE OR REPLACE TABLE bi.hospital_silver.departments
COMMENT 'Departamentos del hospital'
AS
SELECT
    CAST(dept_Id AS BIGINT)  AS dept_id,
    trim(dept_Name)          AS dept_name,
    current_timestamp()      AS dwh_load_date
FROM bi.hospital.department
WHERE dept_Id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY dept_Id ORDER BY dept_Name) = 1;

CREATE OR REPLACE TABLE bi.hospital_silver.wards
COMMENT 'Pabellones; cada uno pertenece a un departamento'
AS
SELECT
    CAST(ward_No AS BIGINT)  AS ward_no,
    trim(ward_Name)          AS ward_name,
    CAST(dept_Id AS BIGINT)  AS dept_id,
    current_timestamp()      AS dwh_load_date
FROM bi.hospital.ward
WHERE ward_No IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY ward_No ORDER BY ward_Name) = 1;

CREATE OR REPLACE TABLE bi.hospital_silver.rooms
COMMENT 'Habitaciones (Standard, Deluxe, Super Deluxe, Operation Theatre)'
AS
SELECT
    CAST(room_No AS BIGINT)  AS room_no,
    CAST(dept_Id AS BIGINT)  AS dept_id,
    trim(room_Type)          AS room_type,
    current_timestamp()      AS dwh_load_date
FROM bi.hospital.room
WHERE room_No IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY room_No ORDER BY room_Type) = 1;

CREATE OR REPLACE TABLE bi.hospital_silver.beds
COMMENT 'Camas; cada una pertenece a un pabellón'
AS
SELECT
    CAST(bed_No  AS BIGINT)  AS bed_no,
    CAST(ward_No AS BIGINT)  AS ward_no,
    current_timestamp()      AS dwh_load_date
FROM bi.hospital.bed
WHERE bed_No IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY bed_No ORDER BY ward_No) = 1;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### 1.2 Personas: pacientes, médicos, enfermería y auxiliares
-- MAGIC Hallazgos del perfilamiento que se corrigen aquí:
-- MAGIC - `doctor.FName` trae el prefijo **"Dr."** (por eso `CONCAT(FName,' ',LName)` daba "Dr. Raza Hasnain"). Se quita y se deja `title`.
-- MAGIC - Error de capitalización **"And"** dentro de palabras: `HAnd Surgeon`, `Siri ChAnd`, `ArjamAnd`.
-- MAGIC - `surgeon_Type` es NULL en 362 de 400 médicos → `'No aplica'` + bandera `is_surgeon`.
-- MAGIC - `contact_No` es `bigint` en pacientes y `string` en médicos → todo pasa a `STRING` (un teléfono no se suma).
-- MAGIC - En `nurse` la columna real es **`conatct_No`** (typo del dataset; el diagrama ER la muestra corregida).
-- MAGIC - `office_No` viene como `double` → `INT`.
-- MAGIC - La dirección del paciente tiene un patrón fijo (`..., Ciudad, Provincia, País`) → se separa en columnas geográficas.

-- COMMAND ----------

CREATE OR REPLACE TABLE bi.hospital_silver.patients
COMMENT 'Pacientes limpios con geografía derivada de la dirección'
AS
WITH src AS (
    SELECT *, split(pt_Address, ',') AS addr_parts
    FROM bi.hospital.patients
    WHERE patient_Id IS NOT NULL
)
SELECT
    CAST(patient_Id AS BIGINT)                              AS patient_id,
    trim(FName)                                             AS first_name,
    trim(LName)                                             AS last_name,
    concat_ws(' ', trim(FName), trim(LName))                AS full_name,
    CASE upper(trim(Gender)) WHEN 'M' THEN 'M' WHEN 'F' THEN 'F' ELSE 'N/D' END AS gender_code,
    CASE upper(trim(Gender))
         WHEN 'M' THEN 'Masculino'
         WHEN 'F' THEN 'Femenino'
         ELSE 'No definido' END                             AS gender,
    -- Una fecha de nacimiento futura es un error de captura: se anula
    CASE WHEN CAST(Date_Of_Birth AS DATE) > current_date() THEN NULL
         ELSE CAST(Date_Of_Birth AS DATE) END               AS birth_date,
    CAST(contact_No AS STRING)                              AS contact_no,
    trim(pt_Address)                                        AS address,
    CASE WHEN size(addr_parts) >= 3 THEN trim(element_at(addr_parts, -3)) END AS city,
    CASE WHEN size(addr_parts) >= 2 THEN trim(element_at(addr_parts, -2)) END AS province,
    CASE WHEN size(addr_parts) >= 1 THEN trim(element_at(addr_parts, -1)) END AS country,
    current_timestamp()                                     AS dwh_load_date
FROM src
QUALIFY ROW_NUMBER() OVER (PARTITION BY patient_Id ORDER BY patient_Id) = 1;

-- COMMAND ----------

CREATE OR REPLACE TABLE bi.hospital_silver.doctors
COMMENT 'Médicos sin prefijo Dr., con capitalización corregida y bandera de cirujano'
AS
WITH src AS (
    SELECT
        *,
        -- Quita "Dr." o "Dr " al inicio (sin tocar nombres como "Drake")
        trim(regexp_replace(FName, '(?i)^\\s*dr(\\.\\s*|\\s+)', '')) AS fname_clean
    FROM bi.hospital.doctor
    WHERE doct_Id IS NOT NULL
)
SELECT
    CAST(doct_Id AS BIGINT)                                         AS doctor_id,
    CAST(dept_Id AS BIGINT)                                         AS dept_id,
    'Dr.'                                                           AS title,
    regexp_replace(fname_clean, '([a-z])And', '$1and')              AS first_name,
    regexp_replace(trim(LName), '([a-z])And', '$1and')              AS last_name,
    concat_ws(' ',
        regexp_replace(fname_clean, '([a-z])And', '$1and'),
        regexp_replace(trim(LName), '([a-z])And', '$1and'))         AS full_name,
    CASE upper(trim(Gender)) WHEN 'M' THEN 'Masculino' WHEN 'F' THEN 'Femenino' ELSE 'No definido' END AS gender,
    trim(CAST(contact_No AS STRING))                                AS contact_no,
    COALESCE(
        regexp_replace(nullif(trim(surgeon_Type), ''), '([a-z])And', '$1and'),
        'No aplica')                                                AS surgeon_type,
    (nullif(trim(surgeon_Type), '') IS NOT NULL)                    AS is_surgeon,
    CAST(office_No AS INT)                                          AS office_no,
    current_timestamp()                                             AS dwh_load_date
FROM src
QUALIFY ROW_NUMBER() OVER (PARTITION BY doct_Id ORDER BY doct_Id) = 1;

-- COMMAND ----------

CREATE OR REPLACE TABLE bi.hospital_silver.nurses
COMMENT 'Personal de enfermería'
AS
SELECT
    CAST(nurse_Id AS BIGINT)                        AS nurse_id,
    CAST(dept_Id  AS BIGINT)                        AS dept_id,
    trim(FName)                                     AS first_name,
    trim(LName)                                     AS last_name,
    concat_ws(' ', trim(FName), trim(LName))        AS full_name,
    CASE upper(trim(Gender)) WHEN 'M' THEN 'Masculino' WHEN 'F' THEN 'Femenino' ELSE 'No definido' END AS gender,
    -- En bronce la columna viene mal escrita: conatct_No (typo del dataset original)
    trim(CAST(conatct_No AS STRING))                AS contact_no,
    current_timestamp()                             AS dwh_load_date
FROM bi.hospital.nurse
WHERE nurse_Id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY nurse_Id ORDER BY nurse_Id) = 1;

CREATE OR REPLACE TABLE bi.hospital_silver.helpers
COMMENT 'Personal auxiliar'
AS
SELECT
    CAST(helper_Id AS BIGINT)                       AS helper_id,
    CAST(dept_Id   AS BIGINT)                       AS dept_id,
    trim(FName)                                     AS first_name,
    trim(LName)                                     AS last_name,
    concat_ws(' ', trim(FName), trim(LName))        AS full_name,
    CASE upper(trim(Gender)) WHEN 'M' THEN 'Masculino' WHEN 'F' THEN 'Femenino' ELSE 'No definido' END AS gender,
    trim(CAST(contact_No AS STRING))                AS contact_no,
    current_timestamp()                             AS dwh_load_date
FROM bi.hospital.helpers
WHERE helper_Id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY helper_Id ORDER BY helper_Id) = 1;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### 1.3 Eventos: citas, estancias, cirugías y registros médicos
-- MAGIC - Estado de la cita traducido (`Completed` → `Completada`, `No-Show` → `No asistió`, ...).
-- MAGIC - Fechas de egreso anteriores al ingreso se anulan y se calculan `length_of_stay_days` y `is_open` (paciente aún hospitalizado).
-- MAGIC - Duración de cirugía en minutos (negativa → NULL).
-- MAGIC - Presión arterial `"120/80"` separada en sistólica y diastólica; temperatura convertida a °C.

-- COMMAND ----------

CREATE OR REPLACE TABLE bi.hospital_silver.appointments
COMMENT 'Citas médicas limpias'
AS
SELECT
    CAST(appoIntment_Id AS BIGINT)                  AS appointment_id,
    CAST(patient_Id     AS BIGINT)                  AS patient_id,
    CAST(doct_Id        AS BIGINT)                  AS doctor_id,
    CAST(appointment_Date AS DATE)                  AS appointment_date,
    trim(reason)                                    AS reason,
    trim(appointment_status)                        AS status_code,
    CASE trim(appointment_status)
         WHEN 'Completed' THEN 'Completada'
         WHEN 'Scheduled' THEN 'Programada'
         WHEN 'Pending'   THEN 'Pendiente'
         WHEN 'Cancelled' THEN 'Cancelada'
         WHEN 'No-Show'   THEN 'No asistió'
         ELSE 'No definido' END                     AS status,
    trim(mode_of_appointment)                       AS appointment_mode,
    trim(mode_of_payment)                           AS payment_method,
    CASE WHEN payment_amount < 0 THEN NULL
         ELSE CAST(payment_amount AS DECIMAL(12,2)) END AS payment_amount,
    current_timestamp()                             AS dwh_load_date
FROM bi.hospital.appointment
WHERE appoIntment_Id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY appoIntment_Id ORDER BY appointment_Date DESC) = 1;

-- COMMAND ----------

CREATE OR REPLACE TABLE bi.hospital_silver.bed_records
COMMENT 'Estancias en cama'
AS
WITH src AS (
    SELECT *,
           CAST(admission_Date AS DATE) AS adm_d,
           CAST(discharge_Date AS DATE) AS dis_d
    FROM bi.hospital.bedrecords
    WHERE admission_Id IS NOT NULL
)
SELECT
    CAST(admission_Id AS BIGINT)                        AS admission_id,
    CAST(bed_No       AS BIGINT)                        AS bed_no,
    CAST(patient_Id   AS BIGINT)                        AS patient_id,
    CAST(nurse_Id     AS BIGINT)                        AS nurse_id,
    CAST(helper_Id    AS BIGINT)                        AS helper_id,
    adm_d                                               AS admission_date,
    CASE WHEN dis_d < adm_d THEN NULL ELSE dis_d END    AS discharge_date,
    CASE WHEN dis_d >= adm_d THEN datediff(dis_d, adm_d) END AS length_of_stay_days,
    (dis_d IS NULL OR dis_d < adm_d)                    AS is_open,
    CASE WHEN amount < 0 THEN NULL ELSE CAST(amount AS DECIMAL(12,2)) END AS amount,
    trim(mode_of_payment)                               AS payment_method,
    current_timestamp()                                 AS dwh_load_date
FROM src
QUALIFY ROW_NUMBER() OVER (PARTITION BY admission_Id ORDER BY admission_Date DESC) = 1;

CREATE OR REPLACE TABLE bi.hospital_silver.room_records
COMMENT 'Estancias en habitación (corrige admisson_ID → admission_id)'
AS
WITH src AS (
    SELECT *,
           CAST(admission_Date AS DATE) AS adm_d,
           CAST(discharge_Date AS DATE) AS dis_d
    FROM bi.hospital.roomrecords
    WHERE admisson_ID IS NOT NULL
)
SELECT
    CAST(admisson_ID AS BIGINT)                         AS admission_id,
    CAST(room_no     AS BIGINT)                         AS room_no,
    CAST(patient_Id  AS BIGINT)                         AS patient_id,
    CAST(nurse_Id    AS BIGINT)                         AS nurse_id,
    CAST(helper_Id   AS BIGINT)                         AS helper_id,
    adm_d                                               AS admission_date,
    CASE WHEN dis_d < adm_d THEN NULL ELSE dis_d END    AS discharge_date,
    CASE WHEN dis_d >= adm_d THEN datediff(dis_d, adm_d) END AS length_of_stay_days,
    (dis_d IS NULL OR dis_d < adm_d)                    AS is_open,
    CASE WHEN amount < 0 THEN NULL ELSE CAST(amount AS DECIMAL(12,2)) END AS amount,
    trim(mode_of_payment)                               AS payment_method,
    current_timestamp()                                 AS dwh_load_date
FROM src
QUALIFY ROW_NUMBER() OVER (PARTITION BY admisson_ID ORDER BY admission_Date DESC) = 1;

-- COMMAND ----------

CREATE OR REPLACE TABLE bi.hospital_silver.surgery_records
COMMENT 'Cirugías con duración en minutos'
AS
WITH src AS (
    SELECT *, timestampdiff(MINUTE, start_Timestamp, end_Timestamp) AS dur
    FROM bi.hospital.surgeryrecord
    WHERE surgery_Id IS NOT NULL
)
SELECT
    CAST(surgery_Id  AS BIGINT)                 AS surgery_id,
    CAST(patient_Id  AS BIGINT)                 AS patient_id,
    CAST(surgeon_Id  AS BIGINT)                 AS surgeon_id,
    CAST(room_no     AS BIGINT)                 AS room_no,
    CAST(nurse_Id    AS BIGINT)                 AS nurse_id,
    CAST(helper_Id   AS BIGINT)                 AS helper_id,
    trim(surgery_Type)                          AS surgery_type,
    CAST(surgery_Date AS DATE)                  AS surgery_date,
    start_Timestamp                             AS start_ts,
    end_Timestamp                               AS end_ts,
    CASE WHEN dur >= 0 THEN dur END             AS duration_minutes,
    nullif(trim(notes), '')                     AS notes,
    current_timestamp()                         AS dwh_load_date
FROM src
QUALIFY ROW_NUMBER() OVER (PARTITION BY surgery_Id ORDER BY surgery_Date DESC) = 1;

-- COMMAND ----------

CREATE OR REPLACE TABLE bi.hospital_silver.medical_records
COMMENT 'Registros clínicos con signos vitales estandarizados'
AS
SELECT
    CAST(record_Id  AS BIGINT)                                  AS record_id,
    CAST(doct_Id    AS BIGINT)                                  AS doctor_id,
    CAST(patient_Id AS BIGINT)                                  AS patient_id,
    CAST(visit_Date AS DATE)                                    AS visit_date,
    CAST(curr_Weight AS DECIMAL(6,2))                           AS weight,
    CAST(curr_height AS DECIMAL(6,2))                           AS height,
    trim(curr_Blood_Pressure)                                   AS blood_pressure,
    -- regexp_extract devuelve '' si no hay coincidencia; try_cast('' AS INT) → NULL
    try_cast(regexp_extract(curr_Blood_Pressure, '^\\s*(\\d+)\\s*/\\s*(\\d+)', 1) AS INT) AS systolic_bp,
    try_cast(regexp_extract(curr_Blood_Pressure, '^\\s*(\\d+)\\s*/\\s*(\\d+)', 2) AS INT) AS diastolic_bp,
    CAST(curr_Temp_F AS DECIMAL(5,1))                           AS temp_f,
    CAST(round((curr_Temp_F - 32) * 5 / 9, 1) AS DECIMAL(5,1))  AS temp_c,
    trim(diagnosis)                                             AS diagnosis,
    trim(treatment)                                             AS treatment,
    CAST(next_Visit AS DATE)                                    AS next_visit_date,
    current_timestamp()                                         AS dwh_load_date
FROM bi.hospital.medicalrecord
WHERE record_Id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY record_Id ORDER BY visit_Date DESC) = 1;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### 1.4 Validación de plata (reconciliación bronce vs. plata)
-- MAGIC Si `diferencia` ≠ 0, la deduplicación o el filtro de llaves nulas eliminó filas: hay que investigarlas antes de seguir.

-- COMMAND ----------

SELECT 'patients' AS tabla, (SELECT count(*) FROM bi.hospital.patients) AS bronce, (SELECT count(*) FROM bi.hospital_silver.patients) AS plata
UNION ALL SELECT 'doctor',        (SELECT count(*) FROM bi.hospital.doctor),        (SELECT count(*) FROM bi.hospital_silver.doctors)
UNION ALL SELECT 'nurse',         (SELECT count(*) FROM bi.hospital.nurse),         (SELECT count(*) FROM bi.hospital_silver.nurses)
UNION ALL SELECT 'helpers',       (SELECT count(*) FROM bi.hospital.helpers),       (SELECT count(*) FROM bi.hospital_silver.helpers)
UNION ALL SELECT 'department',    (SELECT count(*) FROM bi.hospital.department),    (SELECT count(*) FROM bi.hospital_silver.departments)
UNION ALL SELECT 'ward',          (SELECT count(*) FROM bi.hospital.ward),          (SELECT count(*) FROM bi.hospital_silver.wards)
UNION ALL SELECT 'room',          (SELECT count(*) FROM bi.hospital.room),          (SELECT count(*) FROM bi.hospital_silver.rooms)
UNION ALL SELECT 'bed',           (SELECT count(*) FROM bi.hospital.bed),           (SELECT count(*) FROM bi.hospital_silver.beds)
UNION ALL SELECT 'appointment',   (SELECT count(*) FROM bi.hospital.appointment),   (SELECT count(*) FROM bi.hospital_silver.appointments)
UNION ALL SELECT 'bedrecords',    (SELECT count(*) FROM bi.hospital.bedrecords),    (SELECT count(*) FROM bi.hospital_silver.bed_records)
UNION ALL SELECT 'roomrecords',   (SELECT count(*) FROM bi.hospital.roomrecords),   (SELECT count(*) FROM bi.hospital_silver.room_records)
UNION ALL SELECT 'surgeryrecord', (SELECT count(*) FROM bi.hospital.surgeryrecord), (SELECT count(*) FROM bi.hospital_silver.surgery_records)
UNION ALL SELECT 'medicalrecord', (SELECT count(*) FROM bi.hospital.medicalrecord), (SELECT count(*) FROM bi.hospital_silver.medical_records);

-- COMMAND ----------

-- Verificación puntual de la limpieza de médicos: ya no debe aparecer "Dr." ni "And" en medio de palabra
SELECT doctor_id, title, full_name, surgeon_type, is_surgeon
FROM bi.hospital_silver.doctors
WHERE full_name RLIKE '(?i)^dr[ .]' OR full_name RLIKE '[a-z]And' OR surgeon_type RLIKE '[a-z]And';
-- Resultado esperado: 0 filas

-- COMMAND ----------

-- Revisión de presión arterial: filas donde el texto existe pero no se pudo separar
SELECT blood_pressure, count(*) AS filas
FROM bi.hospital_silver.medical_records
WHERE blood_pressure IS NOT NULL AND systolic_bp IS NULL
GROUP BY blood_pressure;
-- Resultado esperado: 0 filas. Si aparecen, ajustar el patrón regexp.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC # CAPA ORO
-- MAGIC Modelo **constelación** (galaxia): 4 tablas de hechos que comparten dimensiones conformadas.
-- MAGIC
-- MAGIC | Hecho | Grano (1 fila = ...) | Dimensiones |
-- MAGIC |---|---|---|
-- MAGIC | `fact_appointments` | una cita | paciente, médico, departamento, fecha |
-- MAGIC | `fact_admissions` | una estancia (cama o habitación) | paciente, cama, habitación, departamento, personal, fecha ingreso/egreso |
-- MAGIC | `fact_surgeries` | una cirugía | paciente, cirujano, habitación, personal, fecha |
-- MAGIC | `fact_medical_records` | una consulta clínica | paciente, médico, fecha |
-- MAGIC
-- MAGIC Llaves sustitutas con `ROW_NUMBER()` ordenado por la llave natural (mismo patrón de BI Bike).

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 2.1 Dimensiones

-- COMMAND ----------

CREATE OR REPLACE VIEW bi.hospital_gold.dim_departments
COMMENT 'Dimensión departamento'
AS
SELECT
    ROW_NUMBER() OVER (ORDER BY dept_id) AS department_key,
    dept_id                              AS department_id,
    dept_name                            AS department_name
FROM bi.hospital_silver.departments;

-- COMMAND ----------

CREATE OR REPLACE VIEW bi.hospital_gold.dim_patients
COMMENT 'Dimensión paciente con edad y grupo etario calculados al día de hoy'
AS
WITH base AS (
    SELECT *,
           CAST(floor(months_between(current_date(), birth_date) / 12) AS INT) AS age
    FROM bi.hospital_silver.patients
)
SELECT
    ROW_NUMBER() OVER (ORDER BY patient_id) AS patient_key,
    patient_id,
    full_name,
    first_name,
    last_name,
    gender,
    birth_date,
    age,
    CASE
        WHEN age IS NULL THEN 'Sin dato'
        WHEN age < 13    THEN '0-12 Niñez'
        WHEN age < 18    THEN '13-17 Adolescencia'
        WHEN age < 30    THEN '18-29 Joven'
        WHEN age < 45    THEN '30-44 Adulto joven'
        WHEN age < 60    THEN '45-59 Adulto'
        ELSE                  '60+ Adulto mayor'
    END                                     AS age_group,
    city,
    province,
    country
FROM base;

-- COMMAND ----------

CREATE OR REPLACE VIEW bi.hospital_gold.dim_doctors
COMMENT 'Dimensión médico con su departamento'
AS
SELECT
    ROW_NUMBER() OVER (ORDER BY d.doctor_id) AS doctor_key,
    d.doctor_id,
    concat(d.title, ' ', d.full_name)        AS doctor_name,
    d.gender,
    d.is_surgeon,
    d.surgeon_type,
    d.office_no,
    dep.department_key,
    dep.department_name
FROM bi.hospital_silver.doctors d
LEFT JOIN bi.hospital_gold.dim_departments dep
       ON d.dept_id = dep.department_id;

-- COMMAND ----------

CREATE OR REPLACE VIEW bi.hospital_gold.dim_staff
COMMENT 'Dimensión personal asistencial: enfermería + auxiliares (role-playing en los hechos)'
AS
WITH staff AS (
    SELECT 'Enfermería' AS role, nurse_id  AS staff_id, full_name, gender, dept_id FROM bi.hospital_silver.nurses
    UNION ALL
    SELECT 'Auxiliar'   AS role, helper_id AS staff_id, full_name, gender, dept_id FROM bi.hospital_silver.helpers
)
SELECT
    ROW_NUMBER() OVER (ORDER BY s.role, s.staff_id) AS staff_key,
    s.role,
    s.staff_id,
    s.full_name                                     AS staff_name,
    s.gender,
    dep.department_key,
    dep.department_name
FROM staff s
LEFT JOIN bi.hospital_gold.dim_departments dep
       ON s.dept_id = dep.department_id;

-- COMMAND ----------

CREATE OR REPLACE VIEW bi.hospital_gold.dim_beds
COMMENT 'Dimensión cama con la jerarquía física aplanada: departamento → pabellón → cama'
AS
SELECT
    ROW_NUMBER() OVER (ORDER BY b.bed_no) AS bed_key,
    b.bed_no,
    w.ward_no,
    w.ward_name,
    dep.department_key,
    dep.department_name
FROM bi.hospital_silver.beds b
LEFT JOIN bi.hospital_silver.wards w
       ON b.ward_no = w.ward_no
LEFT JOIN bi.hospital_gold.dim_departments dep
       ON w.dept_id = dep.department_id;

-- COMMAND ----------

CREATE OR REPLACE VIEW bi.hospital_gold.dim_rooms
COMMENT 'Dimensión habitación'
AS
SELECT
    ROW_NUMBER() OVER (ORDER BY r.room_no) AS room_key,
    r.room_no,
    r.room_type,
    dep.department_key,
    dep.department_name
FROM bi.hospital_silver.rooms r
LEFT JOIN bi.hospital_gold.dim_departments dep
       ON r.dept_id = dep.department_id;

-- COMMAND ----------

CREATE OR REPLACE VIEW bi.hospital_gold.dim_date
COMMENT 'Dimensión calendario generada dinámicamente según el rango de fechas de los hechos'
AS
WITH all_dates AS (
    SELECT appointment_date AS d FROM bi.hospital_silver.appointments
    UNION ALL SELECT admission_date  FROM bi.hospital_silver.bed_records
    UNION ALL SELECT discharge_date  FROM bi.hospital_silver.bed_records
    UNION ALL SELECT admission_date  FROM bi.hospital_silver.room_records
    UNION ALL SELECT discharge_date  FROM bi.hospital_silver.room_records
    UNION ALL SELECT surgery_date    FROM bi.hospital_silver.surgery_records
    UNION ALL SELECT visit_date      FROM bi.hospital_silver.medical_records
    UNION ALL SELECT next_visit_date FROM bi.hospital_silver.medical_records
),
bounds AS (
    SELECT make_date(year(min(d)), 1, 1)   AS start_d,
           make_date(year(max(d)), 12, 31) AS end_d
    FROM all_dates
    WHERE d IS NOT NULL
),
days AS (
    SELECT explode(sequence(start_d, end_d, INTERVAL 1 DAY)) AS full_date
    FROM bounds
)
SELECT
    CAST(date_format(full_date, 'yyyyMMdd') AS INT)  AS date_key,
    full_date,
    year(full_date)                                  AS year,
    quarter(full_date)                               AS quarter,
    concat('T', quarter(full_date))                  AS quarter_name,
    month(full_date)                                 AS month,
    element_at(array('Enero','Febrero','Marzo','Abril','Mayo','Junio','Julio',
                     'Agosto','Septiembre','Octubre','Noviembre','Diciembre'),
               month(full_date))                     AS month_name,
    date_format(full_date, 'yyyy-MM')                AS year_month,
    dayofweek(full_date)                             AS day_of_week,   -- 1 = domingo
    element_at(array('Domingo','Lunes','Martes','Miércoles','Jueves','Viernes','Sábado'),
               dayofweek(full_date))                 AS day_name,
    dayofweek(full_date) IN (1, 7)                   AS is_weekend
FROM days;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 2.2 Hechos

-- COMMAND ----------

CREATE OR REPLACE VIEW bi.hospital_gold.fact_appointments
COMMENT 'Hecho cita: 1 fila por cita'
AS
SELECT
    a.appointment_id,
    p.patient_key,
    d.doctor_key,
    d.department_key,
    CAST(date_format(a.appointment_date, 'yyyyMMdd') AS INT) AS date_key,
    a.reason,
    a.status,
    a.appointment_mode,
    a.payment_method,
    a.payment_amount,
    CASE WHEN a.status_code = 'Completed' THEN 1 ELSE 0 END  AS is_completed,
    CASE WHEN a.status_code = 'No-Show'   THEN 1 ELSE 0 END  AS is_no_show,
    CASE WHEN a.status_code = 'Cancelled' THEN 1 ELSE 0 END  AS is_cancelled
FROM bi.hospital_silver.appointments a
LEFT JOIN bi.hospital_gold.dim_patients p ON a.patient_id = p.patient_id
LEFT JOIN bi.hospital_gold.dim_doctors  d ON a.doctor_id  = d.doctor_id;

-- COMMAND ----------

CREATE OR REPLACE VIEW bi.hospital_gold.fact_admissions
COMMENT 'Hecho estancia: 1 fila por hospitalización, en cama o en habitación'
AS
WITH stays AS (
    SELECT 'Cama' AS stay_type, admission_id, patient_id,
           bed_no, CAST(NULL AS BIGINT) AS room_no,
           nurse_id, helper_id, admission_date, discharge_date,
           length_of_stay_days, is_open, amount, payment_method
    FROM bi.hospital_silver.bed_records
    UNION ALL
    SELECT 'Habitación', admission_id, patient_id,
           CAST(NULL AS BIGINT), room_no,
           nurse_id, helper_id, admission_date, discharge_date,
           length_of_stay_days, is_open, amount, payment_method
    FROM bi.hospital_silver.room_records
)
SELECT
    concat(s.stay_type, '-', s.admission_id)                       AS admission_code,  -- único aunque los ids se repitan entre fuentes
    s.stay_type,
    s.admission_id,
    p.patient_key,
    b.bed_key,
    r.room_key,
    COALESCE(b.department_key, r.department_key)                   AS department_key,
    n.staff_key                                                    AS nurse_key,
    h.staff_key                                                    AS helper_key,
    CAST(date_format(s.admission_date, 'yyyyMMdd') AS INT)         AS admission_date_key,
    CAST(date_format(s.discharge_date, 'yyyyMMdd') AS INT)         AS discharge_date_key,
    s.length_of_stay_days,
    s.is_open,
    s.amount,
    s.payment_method
FROM stays s
LEFT JOIN bi.hospital_gold.dim_patients p ON s.patient_id = p.patient_id
LEFT JOIN bi.hospital_gold.dim_beds     b ON s.bed_no     = b.bed_no
LEFT JOIN bi.hospital_gold.dim_rooms    r ON s.room_no    = r.room_no
LEFT JOIN bi.hospital_gold.dim_staff    n ON n.role = 'Enfermería' AND s.nurse_id  = n.staff_id
LEFT JOIN bi.hospital_gold.dim_staff    h ON h.role = 'Auxiliar'   AND s.helper_id = h.staff_id;

-- COMMAND ----------

CREATE OR REPLACE VIEW bi.hospital_gold.fact_surgeries
COMMENT 'Hecho cirugía: 1 fila por procedimiento'
AS
SELECT
    s.surgery_id,
    p.patient_key,
    d.doctor_key                                          AS surgeon_key,
    r.room_key,
    COALESCE(r.department_key, d.department_key)          AS department_key,
    n.staff_key                                           AS nurse_key,
    h.staff_key                                           AS helper_key,
    CAST(date_format(s.surgery_date, 'yyyyMMdd') AS INT)  AS date_key,
    s.surgery_type,
    s.start_ts,
    s.end_ts,
    s.duration_minutes,
    s.notes
FROM bi.hospital_silver.surgery_records s
LEFT JOIN bi.hospital_gold.dim_patients p ON s.patient_id = p.patient_id
LEFT JOIN bi.hospital_gold.dim_doctors  d ON s.surgeon_id = d.doctor_id
LEFT JOIN bi.hospital_gold.dim_rooms    r ON s.room_no    = r.room_no
LEFT JOIN bi.hospital_gold.dim_staff    n ON n.role = 'Enfermería' AND s.nurse_id  = n.staff_id
LEFT JOIN bi.hospital_gold.dim_staff    h ON h.role = 'Auxiliar'   AND s.helper_id = h.staff_id;

-- COMMAND ----------

CREATE OR REPLACE VIEW bi.hospital_gold.fact_medical_records
COMMENT 'Hecho registro clínico: 1 fila por consulta con signos vitales'
AS
SELECT
    m.record_id,
    p.patient_key,
    d.doctor_key,
    d.department_key,
    CAST(date_format(m.visit_date, 'yyyyMMdd') AS INT)       AS date_key,
    CAST(date_format(m.next_visit_date, 'yyyyMMdd') AS INT)  AS next_visit_date_key,
    datediff(m.next_visit_date, m.visit_date)                AS days_to_next_visit,
    m.diagnosis,
    m.treatment,
    m.weight,
    m.height,
    m.systolic_bp,
    m.diastolic_bp,
    m.temp_c,
    CASE WHEN m.systolic_bp >= 140 OR m.diastolic_bp >= 90 THEN 1 ELSE 0 END AS is_high_bp,
    CASE WHEN m.diagnosis RLIKE '(?i)diabet|hypertens|hipertens|asthma|asma' THEN 1 ELSE 0 END AS is_chronic
FROM bi.hospital_silver.medical_records m
LEFT JOIN bi.hospital_gold.dim_patients p ON m.patient_id = p.patient_id
LEFT JOIN bi.hospital_gold.dim_doctors  d ON m.doctor_id  = d.doctor_id;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 2.3 Validación de oro

-- COMMAND ----------

-- a) Integridad referencial: hechos con llaves huérfanas (esperado: 0 en todas las columnas)
SELECT 'fact_appointments' AS hecho,
       sum(CASE WHEN patient_key IS NULL THEN 1 ELSE 0 END) AS sin_paciente,
       sum(CASE WHEN doctor_key  IS NULL THEN 1 ELSE 0 END) AS sin_medico,
       sum(CASE WHEN date_key NOT IN (SELECT date_key FROM bi.hospital_gold.dim_date) THEN 1 ELSE 0 END) AS sin_fecha
FROM bi.hospital_gold.fact_appointments
UNION ALL
SELECT 'fact_admissions',
       sum(CASE WHEN patient_key IS NULL THEN 1 ELSE 0 END),
       sum(CASE WHEN bed_key IS NULL AND room_key IS NULL THEN 1 ELSE 0 END),
       sum(CASE WHEN admission_date_key NOT IN (SELECT date_key FROM bi.hospital_gold.dim_date) THEN 1 ELSE 0 END)
FROM bi.hospital_gold.fact_admissions
UNION ALL
SELECT 'fact_surgeries',
       sum(CASE WHEN patient_key IS NULL THEN 1 ELSE 0 END),
       sum(CASE WHEN surgeon_key IS NULL THEN 1 ELSE 0 END),
       sum(CASE WHEN date_key NOT IN (SELECT date_key FROM bi.hospital_gold.dim_date) THEN 1 ELSE 0 END)
FROM bi.hospital_gold.fact_surgeries
UNION ALL
SELECT 'fact_medical_records',
       sum(CASE WHEN patient_key IS NULL THEN 1 ELSE 0 END),
       sum(CASE WHEN doctor_key  IS NULL THEN 1 ELSE 0 END),
       sum(CASE WHEN date_key NOT IN (SELECT date_key FROM bi.hospital_gold.dim_date) THEN 1 ELSE 0 END)
FROM bi.hospital_gold.fact_medical_records;

-- COMMAND ----------

-- b) Unicidad de llaves sustitutas (esperado: 0 filas)
SELECT 'dim_patients' AS dim, patient_key AS k, count(*) c FROM bi.hospital_gold.dim_patients GROUP BY patient_key HAVING count(*) > 1
UNION ALL SELECT 'dim_doctors', doctor_key, count(*) FROM bi.hospital_gold.dim_doctors GROUP BY doctor_key HAVING count(*) > 1
UNION ALL SELECT 'dim_staff',   staff_key,  count(*) FROM bi.hospital_gold.dim_staff   GROUP BY staff_key  HAVING count(*) > 1
UNION ALL SELECT 'dim_beds',    bed_key,    count(*) FROM bi.hospital_gold.dim_beds    GROUP BY bed_key    HAVING count(*) > 1
UNION ALL SELECT 'dim_rooms',   room_key,   count(*) FROM bi.hospital_gold.dim_rooms   GROUP BY room_key   HAVING count(*) > 1;

-- COMMAND ----------

-- c) Reconciliación de negocio: el recaudo de citas en oro debe ser igual al de bronce
SELECT
    (SELECT sum(payment_amount) FROM bi.hospital.appointment)              AS recaudo_bronce,
    (SELECT sum(payment_amount) FROM bi.hospital_gold.fact_appointments)   AS recaudo_oro;
-- En el notebook original: General Medicine 830.436 + Cardiology 269.862 + Neurology 195.473
-- + Pulmonology 184.568 + Endocrinology 183.015 = 1.663.354

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 2.4 Ejemplo de consumo: la misma pregunta de negocio, ahora sobre oro

-- COMMAND ----------

-- Recaudo y tasa de inasistencia por departamento y trimestre
SELECT
    dep.department_name                         AS departamento,
    dd.year                                     AS anio,
    dd.quarter_name                             AS trimestre,
    count(*)                                    AS total_citas,
    sum(f.payment_amount)                       AS recaudo,
    round(100 * avg(f.is_no_show), 1)           AS pct_no_asistio
FROM bi.hospital_gold.fact_appointments f
JOIN bi.hospital_gold.dim_departments dep ON f.department_key = dep.department_key
JOIN bi.hospital_gold.dim_date        dd  ON f.date_key       = dd.date_key
GROUP BY dep.department_name, dd.year, dd.quarter_name
ORDER BY anio, trimestre, recaudo DESC;

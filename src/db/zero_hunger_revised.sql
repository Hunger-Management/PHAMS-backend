-- ============================================================
-- PATEROS ZERO HUNGER MANAGEMENT SYSTEM (PHAMS)
-- Database Schema v3 — MySQL 9.6.0
-- Advanced Database Systems | AY 2025-2026
-- ============================================================
-- CHANGELOG:
-- v1 — Original schema (teammate's draft, MariaDB)
-- v2 — Full redesign: ledger model, users, audit_log, triggers,
--       stored procedures, views, indexes. Fixed DECLARE placement
--       and LEAVE label issues.
-- v3 — Fixed trg_family_after_insert: removed UPDATE families
--       from inside a trigger fired by families INSERT
--       (MySQL ER_CANT_UPDATE_USED_TABLE_IN_SF_OR_TRG).
--       Priority score on insert now starts at 0.00 (default)
--       and is computed by trg_member_after_insert once the
--       first family member is added. Audit log only in this trigger.
-- ============================================================

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
SET FOREIGN_KEY_CHECKS = 0;
START TRANSACTION;
SET time_zone = "+00:00";

-- ============================================================
-- TABLE 1: barangays
-- The 10 official barangays of Pateros. Static reference data.
-- ============================================================
CREATE TABLE barangays (
    barangay_id     INT             NOT NULL AUTO_INCREMENT,
    name            VARCHAR(100)    NOT NULL,
    PRIMARY KEY (barangay_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO barangays (name) VALUES
    ('Aguho'),
    ('Magtanggol'),
    ('Martires del ''96'),
    ('Poblacion'),
    ('San Pedro'),
    ('San Roque'),
    ('Santa Ana'),
    ('Santo Rosario-Kanluran'),
    ('Santo Rosario-Silangan'),
    ('Tabacalera');

-- ============================================================
-- TABLE 2: users
-- System accounts. Admin: barangay_id = NULL (all access).
-- Staff: barangay_id = assigned barangay only.
-- Passwords stored as bcrypt hashes — never plain text.
-- ============================================================
CREATE TABLE users (
    user_id         INT             NOT NULL AUTO_INCREMENT,
    full_name       VARCHAR(150)    NOT NULL,
    email           VARCHAR(150)    NOT NULL,
    password_hash   VARCHAR(255)    NOT NULL,
    role            ENUM('Admin','Staff') NOT NULL DEFAULT 'Staff',
    barangay_id     INT             NULL,
    is_active       TINYINT(1)      NOT NULL DEFAULT 1,
    created_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id),
    UNIQUE KEY uq_users_email (email),
    CONSTRAINT fk_users_barangay
        FOREIGN KEY (barangay_id) REFERENCES barangays (barangay_id)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- TABLE 3: families
-- Core beneficiary table. Covers regular households AND
-- individuals without permanent addresses (is_npa = 1).
--
-- priority_score (0-100): computed by sp_compute_priority_score,
-- called from trg_member_after_insert and trg_member_after_update.
-- Starts at 0.00 on family insert; updated after first member added.
--
-- Vulnerability flags: denormalized for fast priority queries.
-- Updated automatically by triggers on family_members changes.
-- ============================================================
CREATE TABLE families (
    family_id               INT             NOT NULL AUTO_INCREMENT,
    household_id            VARCHAR(20)     NULL UNIQUE,
    barangay_id             INT             NOT NULL,
    family_name             VARCHAR(150)    NOT NULL,
    address                 VARCHAR(255)    NULL,
    is_npa                  TINYINT(1)      NOT NULL DEFAULT 0,
    head_of_family          VARCHAR(150)    NULL,
    contact_number          VARCHAR(20)     NULL,
    monthly_income          DECIMAL(10,2)   NULL,
    food_assistance_status  SET('4Ps','Solo Parent','PWD','Senior Citizen','Pregnant/Lactating','None')
                                            NOT NULL DEFAULT 'None',
    has_child_under_5       TINYINT(1)      NOT NULL DEFAULT 0,
    has_senior_member       TINYINT(1)      NOT NULL DEFAULT 0,
    has_pwd_member          TINYINT(1)      NOT NULL DEFAULT 0,
    has_malnourished_member TINYINT(1)      NOT NULL DEFAULT 0,
    member_count            INT             NOT NULL DEFAULT 0,
    priority_score          DECIMAL(5,2)    NOT NULL DEFAULT 0.00,
    is_active               TINYINT(1)      NOT NULL DEFAULT 1,
    deactivated_at          DATETIME        NULL,
    deactivated_by          INT             NULL,
    created_at              DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    created_by              INT             NOT NULL,
    updated_by              INT             NULL,

    PRIMARY KEY (family_id),

    INDEX idx_families_barangay (barangay_id),
    INDEX idx_families_priority (priority_score DESC),
    INDEX idx_families_active (is_active),

    CONSTRAINT fk_families_barangay
        FOREIGN KEY (barangay_id) REFERENCES barangays (barangay_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,

    CONSTRAINT fk_families_created_by
        FOREIGN KEY (created_by) REFERENCES users (user_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,

    CONSTRAINT fk_families_deactivated_by
        FOREIGN KEY (deactivated_by) REFERENCES users (user_id)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- TABLE 4: family_members
-- Individual members per household.
-- date_of_birth stored instead of age (age changes yearly).
-- NPA families require at least one member record.
-- ============================================================
CREATE TABLE family_members (
    member_id           INT             NOT NULL AUTO_INCREMENT,
    family_id           INT             NOT NULL,
    first_name          VARCHAR(100)    NOT NULL,
    last_name           VARCHAR(100)    NOT NULL,
    date_of_birth       DATE            NULL,
    height_cm DECIMAL(5,1) NULL,
	weight_kg DECIMAL(5,2) NULL,
    gender              ENUM('Male','Female','Other') NOT NULL,
    relationship        ENUM('Head','Spouse','Child','Parent','Sibling','Relative','Other')
                                        NOT NULL DEFAULT 'Other',
    is_pwd              TINYINT(1)      NOT NULL DEFAULT 0,
    nutritional_status  ENUM('Normal','Underweight','Severely Underweight','Overweight','Obese','Unknown')
                                        NOT NULL DEFAULT 'Unknown',
    created_at          DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (member_id),
    INDEX idx_members_family (family_id),
    CONSTRAINT fk_members_family
        FOREIGN KEY (family_id) REFERENCES families (family_id)
        ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- TABLE 5: food_supplies
-- Catalog of food types. Does NOT store quantity.
-- Current stock is always derived from inventory_transactions.
-- ============================================================
CREATE TABLE food_supplies (
    food_id             INT             NOT NULL AUTO_INCREMENT,
    food_name           VARCHAR(100)    NOT NULL,
    category            ENUM('Rice','Canned Goods','Fresh Produce','Noodles','Cooking Oil','Other')
                                        NOT NULL DEFAULT 'Other',
    unit                VARCHAR(50)     NOT NULL,
    low_stock_threshold INT             NOT NULL DEFAULT 10,
    is_active           TINYINT(1)      NOT NULL DEFAULT 1,
    PRIMARY KEY (food_id),
    INDEX idx_food_category (category)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- TABLE 6: donors
-- ============================================================
CREATE TABLE donors (
    donor_id        INT             NOT NULL AUTO_INCREMENT,
    donor_name      VARCHAR(150)    NOT NULL,
    donor_type      ENUM('Individual','Organization','Government Agency','NGO','Anonymous')
                                    NOT NULL DEFAULT 'Individual',
    contact_info    VARCHAR(150)    NULL,
    address         VARCHAR(255)    NULL,
    is_active       TINYINT(1)      NOT NULL DEFAULT 1,
    created_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (donor_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- TABLE 7: donations
-- One record per donation event. Line items in donation_items.
-- ============================================================
CREATE TABLE donations (
    donation_id     INT             NOT NULL AUTO_INCREMENT,
    donor_id        INT             NOT NULL,
    donation_date   DATE            NOT NULL,
    notes           TEXT            NULL,
    recorded_by     INT             NOT NULL,
    created_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (donation_id),
    INDEX idx_donations_donor (donor_id),
    INDEX idx_donations_date (donation_date),
    CONSTRAINT fk_donations_donor
        FOREIGN KEY (donor_id) REFERENCES donors (donor_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_donations_recorded_by
        FOREIGN KEY (recorded_by) REFERENCES users (user_id)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- TABLE 8: donation_items
-- One row per food type per donation.
-- Inserting here auto-creates an inventory IN transaction
-- via trg_donation_item_after_insert.
-- ============================================================
CREATE TABLE donation_items (
    item_id         INT             NOT NULL AUTO_INCREMENT,
    donation_id     INT             NOT NULL,
    food_id         INT             NOT NULL,
    quantity        DECIMAL(10,2)   NOT NULL,
    expiry_date     DATE            NULL,
    PRIMARY KEY (item_id),
    INDEX idx_donation_items_donation (donation_id),
    INDEX idx_donation_items_food (food_id),
    INDEX idx_donation_items_expiry (expiry_date),
    CONSTRAINT fk_ditems_donation
        FOREIGN KEY (donation_id) REFERENCES donations (donation_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_ditems_food
        FOREIGN KEY (food_id) REFERENCES food_supplies (food_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_donation_quantity CHECK (quantity > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- TABLE 9: inventory_transactions
-- THE LEDGER. Every food movement is a row here.
-- Current stock = SUM(IN + ADJUST) - SUM(OUT + EXPIRED).
-- Never update a quantity directly — always insert a new row.
--
-- transaction_type:
--   IN      = received from donation
--   OUT     = distributed to a family
--   ADJUST  = manual correction (requires reason)
--   EXPIRED = batch written off (requires reason)
-- ============================================================
CREATE TABLE inventory_transactions (
    txn_id              INT             NOT NULL AUTO_INCREMENT,
    food_id             INT             NOT NULL,
    transaction_type    ENUM('IN','OUT','ADJUST','EXPIRED') NOT NULL,
    quantity            DECIMAL(10,2)   NOT NULL,
    expiry_date         DATE            NULL,
    donation_item_id    INT             NULL,
    distribution_id     INT             NULL,
    reason              VARCHAR(255)    NULL,
    recorded_by         INT             NOT NULL,
    created_at          DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (txn_id),
    INDEX idx_txn_food (food_id),
    INDEX idx_txn_type (transaction_type),
    INDEX idx_txn_date (created_at),
    CONSTRAINT fk_txn_food
        FOREIGN KEY (food_id) REFERENCES food_supplies (food_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_txn_donation_item
        FOREIGN KEY (donation_item_id) REFERENCES donation_items (item_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_txn_recorded_by
        FOREIGN KEY (recorded_by) REFERENCES users (user_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_txn_quantity CHECK (quantity > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- TABLE 10: distributions
-- One record per distribution event. Line items in distribution_items.
-- priority_score_at_time: snapshot of family score at time of distribution.
-- ============================================================
CREATE TABLE distributions (
    distribution_id         INT             NOT NULL AUTO_INCREMENT,
    family_id               INT             NOT NULL,
    barangay_id             INT             NOT NULL,
    distribution_type       ENUM('Package','Feeding Program','Cash Voucher')
                                            NOT NULL DEFAULT 'Package',
    distribution_date       DATE            NOT NULL,
    status                  ENUM('Pending','Released','Received','Cancelled')
                                            NOT NULL DEFAULT 'Pending',
    priority_score_at_time  DECIMAL(5,2)    NULL,
    notes                   TEXT            NULL,
    recorded_by             INT             NOT NULL,
    created_at              DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (distribution_id),
    INDEX idx_dist_family (family_id),
    INDEX idx_dist_barangay (barangay_id),
    INDEX idx_dist_date (distribution_date),
    INDEX idx_dist_status (status),
    CONSTRAINT fk_dist_family
        FOREIGN KEY (family_id) REFERENCES families (family_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_dist_barangay
        FOREIGN KEY (barangay_id) REFERENCES barangays (barangay_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_dist_recorded_by
        FOREIGN KEY (recorded_by) REFERENCES users (user_id)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- TABLE 11: distribution_items
-- ============================================================
CREATE TABLE distribution_items (
    dist_item_id        INT             NOT NULL AUTO_INCREMENT,
    distribution_id     INT             NOT NULL,
    food_id             INT             NOT NULL,
    quantity            DECIMAL(10,2)   NOT NULL,
    PRIMARY KEY (dist_item_id),
    INDEX idx_dist_items_dist (distribution_id),
    INDEX idx_dist_items_food (food_id),
    CONSTRAINT fk_ditems_distribution
        FOREIGN KEY (distribution_id) REFERENCES distributions (distribution_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_ditems_dist_food
        FOREIGN KEY (food_id) REFERENCES food_supplies (food_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_dist_item_quantity CHECK (quantity > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- TABLE 12: low_stock_alerts
-- Auto-populated by trg_check_low_stock when stock drops
-- below food_supplies.low_stock_threshold.
-- ============================================================
CREATE TABLE low_stock_alerts (
    alert_id        INT             NOT NULL AUTO_INCREMENT,
    food_id         INT             NOT NULL,
    current_stock   DECIMAL(10,2)   NOT NULL,
    threshold       INT             NOT NULL,
    is_resolved     TINYINT(1)      NOT NULL DEFAULT 0,
    resolved_by     INT             NULL,
    resolved_at     DATETIME        NULL,
    created_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (alert_id),
    INDEX idx_alerts_food (food_id),
    INDEX idx_alerts_resolved (is_resolved),
    CONSTRAINT fk_alerts_food
        FOREIGN KEY (food_id) REFERENCES food_supplies (food_id)
        ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- TABLE 13: audit_log
-- Immutable. Populated by triggers only — never write manually.
-- Stores JSON snapshots of old/new values for each change.
-- ============================================================
CREATE TABLE audit_log (
    log_id      BIGINT          NOT NULL AUTO_INCREMENT,
    table_name  VARCHAR(100)    NOT NULL,
    record_id   INT             NOT NULL,
    action      ENUM('INSERT','UPDATE','DELETE','DEACTIVATE') NOT NULL,
    old_values  JSON            NULL,
    new_values  JSON            NULL,
    changed_by  INT             NULL,
    changed_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (log_id),
    INDEX idx_audit_table (table_name, record_id),
    INDEX idx_audit_user (changed_by),
    INDEX idx_audit_date (changed_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- VIEWS
-- ============================================================

-- v_current_stock
-- Derives real-time stock from the ledger.
-- Always query this view instead of inventory_transactions directly.
CREATE OR REPLACE VIEW v_current_stock AS
SELECT
    fs.food_id,
    fs.food_name,
    fs.category,
    fs.unit,
    fs.low_stock_threshold,
    COALESCE(SUM(
        CASE
            WHEN it.transaction_type = 'IN'      THEN  it.quantity
            WHEN it.transaction_type = 'OUT'     THEN -it.quantity
            WHEN it.transaction_type = 'EXPIRED' THEN -it.quantity
            WHEN it.transaction_type = 'ADJUST'  THEN  it.quantity
            ELSE 0
        END
    ), 0) AS current_stock,
    CASE
        WHEN COALESCE(SUM(
            CASE
                WHEN it.transaction_type IN ('IN','ADJUST')   THEN  it.quantity
                WHEN it.transaction_type IN ('OUT','EXPIRED') THEN -it.quantity
                ELSE 0
            END
        ), 0) <= fs.low_stock_threshold THEN 1
        ELSE 0
    END AS is_low_stock
FROM food_supplies fs
LEFT JOIN inventory_transactions it ON fs.food_id = it.food_id
WHERE fs.is_active = 1
GROUP BY fs.food_id, fs.food_name, fs.category, fs.unit, fs.low_stock_threshold;

-- v_family_priority_list
-- Active families ordered by priority score descending.
-- Used by distribution screens to determine who gets served next.
CREATE OR REPLACE VIEW v_family_priority_list AS
SELECT
    f.family_id,
    f.family_name,
    f.address,
    f.is_npa,
    b.name                      AS barangay_name,
    f.monthly_income,
    f.food_assistance_status,
    f.member_count,
    f.has_child_under_5,
    f.has_senior_member,
    f.has_pwd_member,
    f.has_malnourished_member,
    f.priority_score,
    MAX(d.distribution_date)    AS last_distribution_date,
    DATEDIFF(CURDATE(), MAX(d.distribution_date)) AS days_since_last_distribution
FROM families f
INNER JOIN barangays b ON f.barangay_id = b.barangay_id
LEFT JOIN distributions d ON f.family_id = d.family_id AND d.status = 'Received'
WHERE f.is_active = 1
GROUP BY
    f.family_id, f.family_name, f.address, f.is_npa,
    b.name, f.monthly_income, f.food_assistance_status,
    f.member_count, f.has_child_under_5, f.has_senior_member,
    f.has_pwd_member, f.has_malnourished_member, f.priority_score
ORDER BY f.priority_score DESC;

-- v_public_transparency_summary
-- Aggregated, non-personal data for the public-facing website.
-- Never expose raw families data publicly — use this view only.
CREATE OR REPLACE VIEW v_public_transparency_summary AS
SELECT
    b.name                          AS barangay_name,
    COUNT(DISTINCT f.family_id)     AS total_families,
    SUM(f.member_count)             AS total_individuals,
    COUNT(DISTINCT CASE
        WHEN d.distribution_id IS NOT NULL THEN f.family_id
    END)                            AS families_assisted,
    COUNT(DISTINCT d.distribution_id) AS total_distributions
FROM barangays b
LEFT JOIN families f      ON b.barangay_id = f.barangay_id AND f.is_active = 1
LEFT JOIN distributions d ON f.family_id = d.family_id AND d.status = 'Received'
GROUP BY b.barangay_id, b.name;

-- ============================================================
-- STORED PROCEDURES & FUNCTIONS
-- ============================================================

DELIMITER $$

-- sp_compute_priority_score
-- Computes 0-100 priority score for one family.
-- Called by trg_member_after_insert and trg_member_after_update.
-- NOT called from trg_family_after_insert (would cause
-- ER_CANT_UPDATE_USED_TABLE_IN_SF_OR_TRG — see v3 changelog).
--
-- Scoring weights:
--   35% income below NCR poverty line (PHP 12,082/mo, PSA 2023)
--   30% malnourished/underweight members
--   20% vulnerable members (child<5, senior 60+, PWD)
--   10% per-capita dependency burden
--    5% days since last distribution
CREATE PROCEDURE sp_compute_priority_score(IN p_family_id INT)
BEGIN
    DECLARE v_income              DECIMAL(10,2) DEFAULT NULL;
    DECLARE v_income_score        DECIMAL(5,2)  DEFAULT 0;
    DECLARE v_malnutrition_score  DECIMAL(5,2)  DEFAULT 0;
    DECLARE v_vulnerability_score DECIMAL(5,2)  DEFAULT 0;
    DECLARE v_dependency_score    DECIMAL(5,2)  DEFAULT 0;
    DECLARE v_recency_score       DECIMAL(5,2)  DEFAULT 0;
    DECLARE v_total_score         DECIMAL(5,2)  DEFAULT 0;
    DECLARE v_member_count        INT           DEFAULT 0;
    DECLARE v_malnourished        INT           DEFAULT 0;
    DECLARE v_has_vulnerable      INT           DEFAULT 0;
    DECLARE v_days_since          INT           DEFAULT 999;
    DECLARE v_per_capita          DECIMAL(10,2) DEFAULT 0;
    DECLARE NCR_POVERTY_LINE      DECIMAL(10,2) DEFAULT 12082.00;

    SELECT monthly_income, member_count
    INTO v_income, v_member_count
    FROM families WHERE family_id = p_family_id;

    -- Component 1: Income (35 pts)
    IF v_income IS NULL THEN
        SET v_income_score = 17.5;
    ELSEIF v_income = 0 THEN
        SET v_income_score = 35;
    ELSEIF v_income < NCR_POVERTY_LINE THEN
        SET v_income_score = 35 * (1 - (v_income / NCR_POVERTY_LINE));
    ELSE
        SET v_income_score = 0;
    END IF;

    -- Component 2: Malnutrition (30 pts)
    SELECT COUNT(*) INTO v_malnourished
    FROM family_members
    WHERE family_id = p_family_id
      AND nutritional_status IN ('Underweight','Severely Underweight');

    IF v_member_count > 0 AND v_malnourished > 0 THEN
        SET v_malnutrition_score = LEAST(30, (v_malnourished / v_member_count) * 30);
    END IF;

    -- Component 3: Vulnerable members (20 pts)
    SELECT COUNT(*) INTO v_has_vulnerable
    FROM family_members
    WHERE family_id = p_family_id
      AND (
          is_pwd = 1
          OR (date_of_birth IS NOT NULL AND TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()) < 5)
          OR (date_of_birth IS NOT NULL AND TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()) >= 60)
      );

    IF v_has_vulnerable > 0 THEN
        SET v_vulnerability_score = LEAST(20, v_has_vulnerable * 5);
    END IF;

    -- Component 4: Dependency burden (10 pts)
    IF v_income IS NOT NULL AND v_member_count > 0 AND v_income > 0 THEN
        SET v_per_capita = v_income / v_member_count;
        IF v_per_capita < (NCR_POVERTY_LINE / 4) THEN
            SET v_dependency_score = 10;
        ELSEIF v_per_capita < (NCR_POVERTY_LINE / 2) THEN
            SET v_dependency_score = 5;
        END IF;
    END IF;

    -- Component 5: Recency (5 pts)
    SELECT COALESCE(DATEDIFF(CURDATE(), MAX(distribution_date)), 999)
    INTO v_days_since
    FROM distributions
    WHERE family_id = p_family_id AND status = 'Received';

    IF v_days_since >= 90 THEN
        SET v_recency_score = 5;
    ELSEIF v_days_since >= 60 THEN
        SET v_recency_score = 3;
    ELSEIF v_days_since >= 30 THEN
        SET v_recency_score = 1;
    END IF;

    SET v_total_score = LEAST(100, GREATEST(0,
        v_income_score + v_malnutrition_score +
        v_vulnerability_score + v_dependency_score + v_recency_score
    ));

    UPDATE families SET
        priority_score          = v_total_score,
        has_malnourished_member = IF(v_malnourished > 0, 1, 0),
        updated_at              = CURRENT_TIMESTAMP
    WHERE family_id = p_family_id;
END$$

-- sp_record_distribution
-- Records a complete distribution atomically (ACID).
-- Validates stock, creates distribution header + line items +
-- inventory OUT transactions in one transaction.
-- If any step fails, everything rolls back.
CREATE PROCEDURE sp_record_distribution(
    IN  p_family_id         INT,
    IN  p_distribution_type VARCHAR(50),
    IN  p_distribution_date DATE,
    IN  p_recorded_by       INT,
    IN  p_notes             TEXT,
    IN  p_food_ids          JSON,
    IN  p_quantities        JSON,
    OUT p_distribution_id   INT,
    OUT p_success           TINYINT,
    OUT p_message           VARCHAR(255)
)
proc_main: BEGIN
    DECLARE v_barangay_id    INT;
    DECLARE v_priority_score DECIMAL(5,2);
    DECLARE v_food_id        INT;
    DECLARE v_quantity       DECIMAL(10,2);
    DECLARE v_stock          DECIMAL(10,2);
    DECLARE v_item_count     INT;
    DECLARE v_i              INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_success = 0;
        SET p_message = 'Transaction failed. All changes rolled back.';
    END;

    SET p_success = 1;
    SET p_message = 'Distribution recorded successfully.';

    START TRANSACTION;

        SELECT barangay_id, priority_score
        INTO v_barangay_id, v_priority_score
        FROM families
        WHERE family_id = p_family_id AND is_active = 1;

        IF v_barangay_id IS NULL THEN
            SET p_success = 0;
            SET p_message = 'Family not found or inactive.';
            ROLLBACK;
            LEAVE proc_main;
        END IF;

        INSERT INTO distributions (
            family_id, barangay_id, distribution_type,
            distribution_date, status, priority_score_at_time,
            notes, recorded_by
        ) VALUES (
            p_family_id, v_barangay_id, p_distribution_type,
            p_distribution_date, 'Pending', v_priority_score,
            p_notes, p_recorded_by
        );

        SET p_distribution_id = LAST_INSERT_ID();
        SET v_item_count = JSON_LENGTH(p_food_ids);

        WHILE v_i < v_item_count DO
            SET v_food_id  = JSON_EXTRACT(p_food_ids,   CONCAT('$[', v_i, ']'));
            SET v_quantity = JSON_EXTRACT(p_quantities,  CONCAT('$[', v_i, ']'));

            SELECT current_stock INTO v_stock
            FROM v_current_stock WHERE food_id = v_food_id;

            IF v_stock < v_quantity THEN
                SET p_success = 0;
                SET p_message = CONCAT('Insufficient stock for food_id ', v_food_id);
                ROLLBACK;
                LEAVE proc_main;
            END IF;

            INSERT INTO distribution_items (distribution_id, food_id, quantity)
            VALUES (p_distribution_id, v_food_id, v_quantity);

            INSERT INTO inventory_transactions (
                food_id, transaction_type, quantity,
                distribution_id, recorded_by
            ) VALUES (
                v_food_id, 'OUT', v_quantity,
                p_distribution_id, p_recorded_by
            );

            SET v_i = v_i + 1;
        END WHILE;

    COMMIT;

    CALL sp_compute_priority_score(p_family_id);
END$$

-- fn_get_current_stock
-- Returns current stock for a single food item.
-- Used in triggers for quick stock checks.
CREATE FUNCTION fn_get_current_stock(p_food_id INT)
RETURNS DECIMAL(10,2)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_stock DECIMAL(10,2) DEFAULT 0;
    SELECT COALESCE(SUM(
        CASE
            WHEN transaction_type IN ('IN','ADJUST') THEN  quantity
            ELSE                                          -quantity
        END
    ), 0) INTO v_stock
    FROM inventory_transactions
    WHERE food_id = p_food_id;
    RETURN v_stock;
END$$

DELIMITER ;

-- ============================================================
-- TRIGGERS
-- ============================================================

DELIMITER $$

-- trg_family_after_insert
-- Writes audit log entry when a family is registered.
-- Does NOT compute priority score here — that would cause
-- ER_CANT_UPDATE_USED_TABLE_IN_SF_OR_TRG (MySQL limitation:
-- cannot UPDATE families inside a trigger fired by families INSERT).
-- Priority score starts at 0.00 and is computed by
-- trg_member_after_insert once the first member is added.
CREATE TRIGGER trg_family_after_insert
AFTER INSERT ON families
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, new_values, changed_by)
    VALUES (
        'families',
        NEW.family_id,
        'INSERT',
        JSON_OBJECT(
            'family_name',    NEW.family_name,
            'barangay_id',    NEW.barangay_id,
            'is_npa',         NEW.is_npa,
            'monthly_income', NEW.monthly_income
        ),
        NEW.created_by
    );
END$$

-- trg_family_after_update
-- Logs all family updates and deactivations to audit_log.
CREATE TRIGGER trg_family_after_update
AFTER UPDATE ON families
FOR EACH ROW
BEGIN
    IF OLD.is_active = 1 AND NEW.is_active = 0 THEN
        INSERT INTO audit_log (table_name, record_id, action, old_values, changed_by)
        VALUES (
            'families', OLD.family_id, 'DEACTIVATE',
            JSON_OBJECT(
                'family_name', OLD.family_name,
                'barangay_id', OLD.barangay_id
            ),
            NEW.deactivated_by
        );
    ELSE
        INSERT INTO audit_log (table_name, record_id, action, old_values, new_values, changed_by)
        VALUES (
            'families', OLD.family_id, 'UPDATE',
            JSON_OBJECT(
                'monthly_income',         OLD.monthly_income,
                'food_assistance_status', OLD.food_assistance_status,
                'priority_score',         OLD.priority_score
            ),
            JSON_OBJECT(
                'monthly_income',         NEW.monthly_income,
                'food_assistance_status', NEW.food_assistance_status,
                'priority_score',         NEW.priority_score
            ),
            NEW.updated_by
        );
    END IF;
END$$

-- trg_member_after_insert
-- After a member is added: updates vulnerability flags, member_count,
-- then calls sp_compute_priority_score.
-- Safe to UPDATE families here because this trigger fires on
-- family_members, not families — no circular reference.
CREATE TRIGGER trg_member_after_insert
AFTER INSERT ON family_members
FOR EACH ROW
BEGIN
    UPDATE families SET
        member_count      = (SELECT COUNT(*) FROM family_members
                             WHERE family_id = NEW.family_id),
        has_child_under_5 = (SELECT COUNT(*) > 0 FROM family_members
                             WHERE family_id = NEW.family_id
                               AND date_of_birth IS NOT NULL
                               AND TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()) < 5),
        has_senior_member = (SELECT COUNT(*) > 0 FROM family_members
                             WHERE family_id = NEW.family_id
                               AND date_of_birth IS NOT NULL
                               AND TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()) >= 60),
        has_pwd_member    = (SELECT COUNT(*) > 0 FROM family_members
                             WHERE family_id = NEW.family_id AND is_pwd = 1),
        updated_at        = CURRENT_TIMESTAMP
    WHERE family_id = NEW.family_id;

    CALL sp_compute_priority_score(NEW.family_id);
END$$

-- trg_member_after_update
-- Recomputes priority score when nutritional status, PWD flag,
-- or date_of_birth changes on any member.
CREATE TRIGGER trg_member_after_update
AFTER UPDATE ON family_members
FOR EACH ROW
BEGIN
    IF OLD.nutritional_status <> NEW.nutritional_status
       OR OLD.is_pwd <> NEW.is_pwd
       OR (OLD.date_of_birth <> NEW.date_of_birth
           OR (OLD.date_of_birth IS NULL     AND NEW.date_of_birth IS NOT NULL)
           OR (OLD.date_of_birth IS NOT NULL AND NEW.date_of_birth IS NULL))
    THEN
        UPDATE families SET
            has_child_under_5 = (SELECT COUNT(*) > 0 FROM family_members
                                 WHERE family_id = NEW.family_id
                                   AND date_of_birth IS NOT NULL
                                   AND TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()) < 5),
            has_senior_member = (SELECT COUNT(*) > 0 FROM family_members
                                 WHERE family_id = NEW.family_id
                                   AND date_of_birth IS NOT NULL
                                   AND TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()) >= 60),
            has_pwd_member    = (SELECT COUNT(*) > 0 FROM family_members
                                 WHERE family_id = NEW.family_id AND is_pwd = 1),
            updated_at        = CURRENT_TIMESTAMP
        WHERE family_id = NEW.family_id;

        CALL sp_compute_priority_score(NEW.family_id);
    END IF;
END$$

-- trg_check_low_stock
-- After every OUT or EXPIRED inventory transaction, checks if
-- stock fell below threshold and creates an unresolved alert.
-- Only one open alert per food item is created at a time.
CREATE TRIGGER trg_check_low_stock
AFTER INSERT ON inventory_transactions
FOR EACH ROW
BEGIN
    DECLARE v_current_stock DECIMAL(10,2);
    DECLARE v_threshold     INT;
    DECLARE v_open_alert    INT;

    IF NEW.transaction_type IN ('OUT','EXPIRED') THEN
        SET v_current_stock = fn_get_current_stock(NEW.food_id);

        SELECT low_stock_threshold INTO v_threshold
        FROM food_supplies WHERE food_id = NEW.food_id;

        IF v_current_stock <= v_threshold THEN
            SELECT COUNT(*) INTO v_open_alert
            FROM low_stock_alerts
            WHERE food_id = NEW.food_id AND is_resolved = 0;

            IF v_open_alert = 0 THEN
                INSERT INTO low_stock_alerts (food_id, current_stock, threshold)
                VALUES (NEW.food_id, v_current_stock, v_threshold);
            END IF;
        END IF;
    END IF;
END$$

-- trg_donation_item_after_insert
-- Auto-creates inventory IN transaction whenever a donation item
-- is recorded. Keeps donations and inventory always in sync.
CREATE TRIGGER trg_donation_item_after_insert
AFTER INSERT ON donation_items
FOR EACH ROW
BEGIN
    DECLARE v_recorded_by INT;

    SELECT recorded_by INTO v_recorded_by
    FROM donations WHERE donation_id = NEW.donation_id;

    INSERT INTO inventory_transactions (
        food_id, transaction_type, quantity,
        expiry_date, donation_item_id, recorded_by
    ) VALUES (
        NEW.food_id, 'IN', NEW.quantity,
        NEW.expiry_date, NEW.item_id, v_recorded_by
    );
END$$

DELIMITER ;

-- ============================================================
-- ADDITIONAL INDEXES
-- B-tree indexes for the most common query patterns.
-- ============================================================

-- "Show all active families in barangay X ordered by priority"
CREATE INDEX idx_families_barangay_priority
    ON families (barangay_id, is_active, priority_score DESC);

-- "Show distribution history for a family by date"
CREATE INDEX idx_dist_family_date
    ON distributions (family_id, distribution_date DESC);

-- "Find items expiring within 30 days"
CREATE INDEX idx_expiry_alert
    ON donation_items (expiry_date);

-- ============================================================
-- END OF SCHEMA v3
-- ============================================================

SET FOREIGN_KEY_CHECKS = 1;
COMMIT;
const pool = require("../db/pool");

// GET /api/families
// Admin sees all active families
// Staff sees only their assigned barangay
// ─────────────────────────────────────────
const getAllFamilies = async (req, res) => {
	try {
		let query = `
      SELECT
        f.family_id,
        f.family_name,
        f.address,
        f.is_npa,
        f.monthly_income,
        f.food_assistance_status,
        f.member_count,
        f.priority_score,
        f.is_active,
        f.created_at,
        b.name AS barangay_name
      FROM families f
      JOIN barangays b ON f.barangay_id = b.barangay_id
      WHERE f.is_active = 1
    `;

		const params = [];

		// Staff can only see their own barangay
		if (req.user.role === "Staff") {
			query += " AND f.barangay_id = ?";
			params.push(req.user.barangay_id);
		}

		query += " ORDER BY f.priority_score DESC";

		const [rows] = await pool.query(query, params);
		return res.status(200).json({ families: rows });
	} catch (err) {
		console.error("getAllFamilies error:", err);
		return res.status(500).json({ message: "Internal server error." });
	}
};


// GET /api/families/priority
// Reads from the v_family_priority_list view
// ─────────────────────────────────────────
const getPriorityList = async (req, res) => {
	try {
		let query = "SELECT * FROM v_family_priority_list";
		const params = [];

		if (req.user.role === "Staff") {
			query += " WHERE barangay_name = (SELECT name FROM barangays WHERE barangay_id = ?)";
			params.push(req.user.barangay_id);
		}

		const [rows] = await pool.query(query, params);
		return res.status(200).json({ families: rows });
	} catch (err) {
		console.error("getPriorityList error:", err);
		return res.status(500).json({ message: "Internal server error." });
	}
};


// GET /api/families/:id
// Returns family + all their members
// ─────────────────────────────────────────
const getFamilyById = async (req, res) => {
	const { id } = req.params;

	try {
		const [familyRows] = await pool.query(
			`SELECT f.*, b.name AS barangay_name
       FROM families f
       JOIN barangays b ON f.barangay_id = b.barangay_id
       WHERE f.family_id = ? AND f.is_active = 1`,
			[id]
		);

		if (familyRows.length === 0) {
			return res.status(404).json({ message: "Family not found." });
		}

		const family = familyRows[0];

		// Staff cannot view families outside their barangay
		if (req.user.role === "Staff" && family.barangay_id !== req.user.barangay_id) {
			return res.status(403).json({ message: "Forbidden." });
		}

		const [memberRows] = await pool.query(
			`SELECT * FROM family_members WHERE family_id = ?`,
			[id]
		);

		return res.status(200).json({
			family,
			members: memberRows,
		});
	} catch (err) {
		console.error("getFamilyById error:", err);
		return res.status(500).json({ message: "Internal server error." });
	}
};

const BARANGAY_CODES = {
	1: 'AGU', 2: 'MAG', 3: 'MAR', 4: 'POB', 5: 'SPD',
	6: 'SRQ', 7: 'STA', 8: 'SRK', 9: 'SRS', 10: 'TAB'
}

const generateHouseholdId = async (conn, barangayId) => {
	const code = BARANGAY_CODES[barangayId] || 'UNK'
	const year = new Date().getFullYear()
	const prefix = `${code}-${year}-`

	// counts existing households in this barangay this year to get next sequence
	const [rows] = await conn.query(
		`SELECT COUNT(*) AS count FROM families
     WHERE barangay_id = ? AND household_id LIKE ?`,
		[barangayId, `${prefix}%`]
	)

	const sequence = (rows[0].count + 1).toString().padStart(4, '0')
	return `${prefix}${sequence}`
}

// POST /api/families
// Register a new family with members
// Includes deduplication check
// ─────────────────────────────────────────
const createFamily = async (req, res) => {
	const {
		family_name,
		address,
		is_npa,
		barangay_id,
		head_of_family,
		contact_number,
		monthly_income,
		food_assistance_status,
		members,
	} = req.body;

	if (!family_name || !barangay_id || !members || members.length === 0) {
		return res.status(400).json({
			message: "family_name, barangay_id, and at least one member are required.",
		});
	}

	// Validate: exactly one member must be Head
	const headCount = members.filter(m => m.relationship === 'Head').length
	if (headCount === 0) {
		return res.status(400).json({
			message: 'At least one family member must be designated as Head of Family.'
		})
	}
	if (headCount > 1) {
		return res.status(400).json({
			message: 'Only one family member can be designated as Head of Family.'
		})
	}

	// Staff can only register families in their own barangay
	if (req.user.role === "Staff" && parseInt(barangay_id) !== req.user.barangay_id) {
		return res.status(403).json({
			message: "You can only register families in your assigned barangay.",
		});
	}

	const conn = await pool.getConnection();

	try {
		await conn.beginTransaction();

		// Deduplication check
		// Flag if a family with same name AND same address in same barangay already exists
		const [duplicates] = await conn.query(
			`SELECT family_id FROM families
       WHERE family_name = ? AND barangay_id = ? AND is_active = 1
       AND (address = ? OR (is_npa = 1 AND ? = 1))`,
			[family_name, barangay_id, address || null, is_npa ? 1 : 0]
		);

		if (duplicates.length > 0) {
			await conn.rollback();
			return res.status(409).json({
				message: "A family with this name and address already exists in this barangay.",
				existing_family_id: duplicates[0].family_id,
			});
		}

		// Generate household ID
		const householdId = await generateHouseholdId(conn, barangay_id)

		// Insert family
		const [familyResult] = await conn.query(
			`INSERT INTO families (
    household_id, barangay_id, family_name, address, is_npa,
    head_of_family, contact_number, monthly_income,
    food_assistance_status, member_count, created_by
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			[
				householdId,
				barangay_id,
				family_name,
				address || null,
				is_npa ? 1 : 0,
				head_of_family || null,
				contact_number || null,
				monthly_income || null,
				food_assistance_status || 'None',
				members.length,
				req.user.user_id,
			]
		)

		const newFamilyId = familyResult.insertId;

		// Insert members
		for (const member of members) {
			if (!member.first_name || !member.last_name || !member.gender) {
				await conn.rollback();
				return res.status(400).json({
					message: "Each member must have first_name, last_name, and gender.",
				});
			}

			await conn.query(
				`INSERT INTO family_members (
    family_id, first_name, last_name, date_of_birth,
    gender, relationship, is_pwd, nutritional_status,
    height_cm, weight_kg
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				[
					newFamilyId,
					member.first_name,
					member.last_name,
					member.date_of_birth || null,
					member.gender,
					member.relationship || 'Other',
					member.is_pwd ? 1 : 0,
					member.nutritional_status || 'Unknown',
					member.height_cm || null,
					member.weight_kg || null,
				]
			)
		}

		await conn.commit();

		// Note: priority score is computed automatically by the
		// trg_family_after_insert trigger in the database

		return res.status(201).json({
			message: 'Family registered successfully.',
			family_id: newFamilyId,
			household_id: householdId,
		})
	} catch (err) {
		await conn.rollback();
		console.error("createFamily error:", err);
		return res.status(500).json({ message: "Internal server error." });
	} finally {
		conn.release();
	}
};


// PUT /api/families/:id
// Update family information
// ─────────────────────────────────────────
const updateFamily = async (req, res) => {
	const { id } = req.params;
	const {
		family_name,
		address,
		head_of_family,
		contact_number,
		monthly_income,
		food_assistance_status,
	} = req.body;

	try {
		// Checking if family exists + get barangay
		const [rows] = await pool.query(
			"SELECT * FROM families WHERE family_id = ? AND is_active = 1",
			[id]
		);

		if (rows.length === 0) {
			return res.status(404).json({ message: "Family not found." });
		}

		const family = rows[0];

		// Staff cannot edit families outside their barangay
		if (req.user.role === "Staff" && family.barangay_id !== req.user.barangay_id) {
			return res.status(403).json({ message: "Forbidden." });
		}

		await pool.query(
			`UPDATE families SET
        family_name           = COALESCE(?, family_name),
        address               = COALESCE(?, address),
        head_of_family        = COALESCE(?, head_of_family),
        contact_number        = COALESCE(?, contact_number),
        monthly_income        = COALESCE(?, monthly_income),
        food_assistance_status = COALESCE(?, food_assistance_status),
        updated_by            = ?,
        updated_at            = CURRENT_TIMESTAMP
      WHERE family_id = ?`,
			[
				family_name || null,
				address || null,
				head_of_family || null,
				contact_number || null,
				monthly_income || null,
				food_assistance_status || null,
				req.user.user_id,
				id,
			]
		);

		return res.status(200).json({ message: "Family updated successfully." });
	} catch (err) {
		console.error("updateFamily error:", err);
		return res.status(500).json({ message: "Internal server error." });
	}
};


// DELETE /api/families/:id
// Soft delete — sets is_active = 0
// Never hard deletes a beneficiary record
// ─────────────────────────────────────────
const deactivateFamily = async (req, res) => {
	const { id } = req.params;

	try {
		const [rows] = await pool.query(
			"SELECT * FROM families WHERE family_id = ? AND is_active = 1",
			[id]
		);

		if (rows.length === 0) {
			return res.status(404).json({ message: "Family not found or already inactive." });
		}

		const family = rows[0];

		// Staff cannot deactivate families outside their barangay
		if (req.user.role === "Staff" && family.barangay_id !== req.user.barangay_id) {
			return res.status(403).json({ message: "Forbidden." });
		}

		await pool.query(
			`UPDATE families SET
        is_active       = 0,
        deactivated_at  = CURRENT_TIMESTAMP,
        deactivated_by  = ?
      WHERE family_id = ?`,
			[req.user.user_id, id]
		);

		return res.status(200).json({ message: "Family deactivated successfully." });
	} catch (err) {
		console.error("deactivateFamily error:", err);
		return res.status(500).json({ message: "Internal server error." });
	}
};

module.exports = {
	getAllFamilies,
	getPriorityList,
	getFamilyById,
	createFamily,
	updateFamily,
	deactivateFamily,
};
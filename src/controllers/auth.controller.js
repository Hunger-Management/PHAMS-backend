const pool = require("../db/pool");
const bcrypt = require("bcrypt");
const jwt = require("jsonwebtoken");

const login = async (req, res) => {
    const { email, password } = req.body;

    if (!email || !password) {
        return res.status(400).json({ message: "Email and password are required." });
    }

    try {
        const [rows] = await pool.query(
        "SELECT * FROM users WHERE email = ? AND is_active = 1",
        [email]
        );

        if (rows.length === 0) {
        return res.status(401).json({ message: "Invalid email or password." });
        }

        const user = rows[0];
        const isMatch = await bcrypt.compare(password, user.password_hash);

        if (!isMatch) {
        return res.status(401).json({ message: "Invalid email or password." });
        }

        const token = jwt.sign(
        {
            user_id: user.user_id,
            role: user.role,
            barangay_id: user.barangay_id, // null for admin, set for staff
        },
        process.env.JWT_SECRET,
        { expiresIn: "8h" }
        );

        return res.status(200).json({
        message: "Login successful.",
        token,
        user: {
            user_id: user.user_id,
            full_name: user.full_name,
            role: user.role,
            barangay_id: user.barangay_id,
        },
        });
    } catch (err) {
        console.error("Login error:", err);
        return res.status(500).json({ message: "Internal server error." });
    }
};

module.exports = { login };
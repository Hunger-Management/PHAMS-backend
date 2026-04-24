# PHAMS Backend

Backend API for the Pateros Hunger Assistance Management System (PHAMS), built with Node.js, Express, and MySQL.

This document is intended to be the main working guide for team members.

## 1. Current Scope

Implemented features in this backend:

- Login and JWT-based authentication
- Role-based access control (`Admin`, `Staff`)
- Family management:
	- List families
	- Priority list view
	- Get single family with members
	- Register family with members
	- Update family info
	- Soft delete (deactivate) family
- MySQL schema with stored procedures, triggers, and views for priority scoring and audit support

## 2. Tech Stack

- Node.js
- Express
- MySQL (`mysql2/promise`)
- JWT (`jsonwebtoken`)
- Password hashing (`bcrypt`)
- CORS
- dotenv

## 3. Prerequisites

- Node.js 18+
- npm
- MySQL 8+ (or compatible MySQL server)

## 4. Setup

### 4.1 Install dependencies

```bash
npm install
```

### 4.2 Configure environment

Copy `.env.example` to `.env`, then set your values.

Required variables:

```env
DB_HOST=localhost
DB_USER=root
DB_PASSWORD=
DB_NAME=zero_hunger
PORT=5000
JWT_SECRET=your_secret_here
```

Notes:

- `JWT_SECRET` must be set, or token signing/verification will fail.
- The app defaults to port `5000` if `PORT` is not set.

### 4.3 Create database schema

Use the SQL file:

- `src/db/zero_hunger_revised.sql`

Example via MySQL CLI:

```bash
mysql -u root -p zero_hunger < src/db/zero_hunger_revised.sql
```

If the database does not exist yet, create it first:

```sql
CREATE DATABASE zero_hunger;
```

## 5. Run the Backend

Development mode (nodemon):

```bash
npm run dev
```

Production mode:

```bash
npm start
```

On success, you should see:

- `MySQL connected successfully`
- `Server running on port <PORT>`

## 6. Scripts

- `npm start` -> `node src/index.js`
- `npm run dev` -> `nodemon src/index.js`

## 7. Authentication and Authorization

### 7.1 Login

- `POST /api/auth/login`

Body:

```json
{
	"email": "user@example.com",
	"password": "your_password"
}
```

Success response includes:

- `token` (JWT, expires in 8 hours)
- `user` object (`user_id`, `full_name`, `role`, `barangay_id`)

### 7.2 Protected endpoints

Send header on protected routes:

```http
Authorization: Bearer <token>
```

### 7.3 Role rules

- `Admin`
	- Can access all families across barangays.
- `Staff`
	- Can only view/create/update/deactivate families in their assigned `barangay_id`.

## 8. API Reference (Implemented)

Base URL (local):

```text
http://localhost:5000
```

### 8.1 Health

- `GET /`

Response:

```text
PHAMS Backend Running
```

### 8.2 Auth

- `POST /api/auth/login`

### 8.3 Families (Protected: Admin/Staff)

- `GET /api/families`
	- Admin: all active families
	- Staff: only active families in own barangay

- `GET /api/families/priority`
	- Reads from DB view `v_family_priority_list`
	- Staff is filtered to own barangay

- `GET /api/families/:id`
	- Returns family details + members

- `POST /api/families`
	- Registers a new family with member list
	- Deduplication check is enforced

- `PUT /api/families/:id`
	- Updates family information

- `DELETE /api/families/:id`
	- Soft delete only (`is_active = 0`)

#### Sample payload for create family

```json
{
	"family_name": "Dela Cruz Family",
	"address": "123 Example St",
	"is_npa": false,
	"barangay_id": 1,
	"head_of_family": "Juan Dela Cruz",
	"contact_number": "09123456789",
	"monthly_income": 8000,
	"food_assistance_status": "4Ps",
	"members": [
		{
			"first_name": "Juan",
			"last_name": "Dela Cruz",
			"date_of_birth": "1988-02-14",
			"gender": "Male",
			"relationship": "Head",
			"is_pwd": false,
			"nutritional_status": "Normal"
		},
		{
			"first_name": "Maria",
			"last_name": "Dela Cruz",
			"date_of_birth": "1990-06-20",
			"gender": "Female",
			"relationship": "Spouse",
			"is_pwd": false,
			"nutritional_status": "Normal"
		}
	]
}
```

## 9. Database Notes

The SQL schema includes:

- Core tables (`users`, `barangays`, `families`, `family_members`, etc.)
- Views:
	- `v_family_priority_list`
	- `v_current_stock`
	- `v_public_transparency_summary`
- Stored procedure for score computation:
	- `sp_compute_priority_score`
- Triggers that update family indicators and recalculate priority score

Important behavior:

- Family priority score is computed automatically by database logic.
- Family deletion is soft delete for data integrity and auditability.

## 10. Project Structure

```text
.
|-- package.json
|-- README.md
`-- src
		|-- index.js
		|-- controllers
		|   |-- auth.controller.js
		|   `-- families.controller.js
		|-- db
		|   |-- pool.js
		|   `-- zero_hunger_revised.sql
		|-- middleware
		|   |-- authenticate.js
		|   `-- authorize.js
		`-- routes
				|-- auth.routes.js
				`-- families.routes.js
```

## 11. Common Team Workflow

1. Pull latest changes.
2. Run `npm install` if dependencies changed.
3. Ensure local MySQL is running.
4. Verify `.env` values.
5. Start backend with `npm run dev`.
6. Test login first, then call protected family endpoints with the JWT token.

## 12. Current Limitations

- No registration endpoint yet (login only).
- No automated test suite currently configured.
- API docs are maintained in this README for now (no Swagger/OpenAPI yet).
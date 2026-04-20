# PHAMS-backend

Backend service for the PHAMS project, built with Express and Node.js.

## Tech Stack

- Node.js
- Express
- PostgreSQL driver (pg)
- CORS
- dotenv

## Prerequisites

- Node.js 18+ recommended
- npm

## Installation

1. Clone the repository.
2. Install dependencies:

```bash
npm install
```

## Environment Variables

Create a `.env` file in the project root.

Current variables used by the app:

- `PORT` (optional): server port, defaults to `5000`

Example:

```env
PORT=5000
```

## Running the Server

Start in development mode (with automatic reload):

```bash
npm run dev
```

Start in production mode:

```bash
npm start
```

## Available Scripts

- `npm start`: runs `node src/index.js`
- `npm run dev`: runs `nodemon src/index.js`

## API

### Health Check

- Method: `GET`
- Route: `/`
- Response: `PHAMS Backend Running`

Example:

```bash
curl http://localhost:5000/
```

## Project Structure

```text
.
|-- package.json
|-- README.md
`-- src
	|-- index.js
	|-- controllers/
	|-- db/
	|   |-- pool.js
	|   `-- schema.sql
	|-- middleware/
	`-- routes/
```

## Current Status

The project is currently scaffolded with a running Express server and base folders for controllers, routes, middleware, and database files.
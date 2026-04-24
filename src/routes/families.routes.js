const express = require("express");
const router = express.Router();
const familiesController = require("../controllers/families.controller");
const authenticate = require("../middleware/authenticate");
const authorize = require("../middleware/authorize");

// GET all families (admin sees all, staff sees only their barangay)
router.get(
    "/",
    authenticate,
    authorize("Admin", "Staff"),
    familiesController.getAllFamilies
);

// GET families ordered by priority score
router.get(
    "/priority",
    authenticate,
    authorize("Admin", "Staff"),
    familiesController.getPriorityList
);

// GET single family with members
router.get(
    "/:id",
    authenticate,
    authorize("Admin", "Staff"),
    familiesController.getFamilyById
);

// POST register new family (with members)
router.post(
    "/",
    authenticate,
    authorize("Admin", "Staff"),
    familiesController.createFamily
);

// PUT update family info
router.put(
    "/:id",
    authenticate,
    authorize("Admin", "Staff"),
    familiesController.updateFamily
);

// DELETE soft delete (deactivate) a family
router.delete(
    "/:id",
    authenticate,
    authorize("Admin", "Staff"),
    familiesController.deactivateFamily
);

module.exports = router;
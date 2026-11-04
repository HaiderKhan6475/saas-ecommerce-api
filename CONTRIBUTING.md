# Contributing

## Development Workflow

1. Create a feature branch from `main`.
2. Make changes on the feature branch.
3. Run the project's tests and quality checks.
4. Push the feature branch to GitHub.
5. Open a Pull Request targeting `main`.
6. Wait for the required `Required CI gate` check to pass.
7. Merge the Pull Request after all required checks pass.

## Important Rules

- Do not push directly to `main`.
- Do not force-push to protected branches.
- Keep SQLite as the project's only database.
- Never commit `.env` files, secrets, or local database files.

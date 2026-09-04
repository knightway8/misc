# AGENTS.md

## Project priorities

- Security and data integrity are more important than adding features quickly.
- Keep the application framework-free unless a dependency is clearly necessary.
- Do not add production dependencies without explicit approval.
- Preserve the existing visual design unless the task specifically changes it.
- Never collect or store visitor IP addresses.
- Never place secrets, passwords, or application keys in the repository.

## Required security practices

- Escape all untrusted output according to its HTML context.
- Use prepared statements for every database query.
- Require CSRF protection for every state-changing browser request.
- Perform authorization checks in controllers, not only in templates.
- Treat uploaded files as hostile.
- Decode and re-encode accepted images.
- Store uploads outside executable PHP locations.
- Do not trust MIME types or filename extensions supplied by the browser.
- Do not use eval, shell execution, dynamic includes, or unsafe deserialization.
- Regenerate sessions after authentication changes.
- Use secure, HttpOnly, and SameSite cookies in production.

## Required completion checks

- Inspect the relevant code before editing.
- Make the smallest focused change.
- Run PHP syntax checks on every changed PHP file.
- Run the complete automated test suite.
- Run JavaScript and CSS checks when those files change.
- Run database integrity and migration tests when schema code changes.
- Review the final diff for unrelated modifications.
- Clearly state any test that could not run and why.
- Never claim a check passed unless it actually executed successfully.


## Rust requirements

- Prefer safe Rust.
- Do not introduce unsafe code without explicit approval and written justification.
- Run cargo fmt --check.
- Run cargo clippy with warnings treated as errors.
- Run cargo test.
- Review all new crates before adding them.
- Avoid invoking system shells with untrusted input.















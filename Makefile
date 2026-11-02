.PHONY: deploy sync-secrets

# Every push to main is deployed by the GitHub Action (.github/workflows/deploy.yml).
# This is the way to deploy from this machine.
#
# The secrets of Kamal live in the 1Password Environment ike-emails-prod, see
# .kamal/secrets. The registry password is the GitHub token of the gh CLI, which
# needs the write:packages scope: gh auth refresh -s write:packages
#
# The image is built on the server, as the amd64 build under emulation on an Apple
# Silicon Mac crashes Erlang, see config/deploy.yml.
deploy:
	KAMAL_BUILD_ON_SERVER=1 op run --environment p3mdfiiyqkk6lf75sahcxlv6l4 -- kamal deploy

# Copies the secrets of the 1Password Environment to the production environment of the
# repository, where the GitHub Action reads them, and the SSH key the Action deploys
# with, which is the item "ike-emails GitHub Actions deploy key" in the Employee vault
# (its public key is in ~/.ssh/authorized_keys of deploy on the server). Run it again
# after changing one. The values go from 1Password to GitHub and are never printed.
sync-secrets:
	op run --environment p3mdfiiyqkk6lf75sahcxlv6l4 -- sh -c '\
		for name in SECRET_KEY_BASE POSTGRES_PASSWORD BANK_API_TOKEN AWS_ACCESS_KEY_ID \
			AWS_SECRET_ACCESS_KEY ELORUS_ORGANIZATION_ID ELORUS_API_TOKEN ANTHROPIC_API_KEY \
			SENTRY_DSN; do \
			printenv $$name | gh secret set $$name --env production || exit 1; \
		done'
	op read "op://Employee/ike-emails GitHub Actions deploy key/private key?ssh-format=openssh" \
		| gh secret set DEPLOY_SSH_KEY --env production

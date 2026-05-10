# Corpus

Minimal tooling for a personal wiki workflow:

- One private GitHub repo per vault.
- Vault files synced to devices via Syncthing.
- Git operations run on VPS only (cron loop).
- Claude Code uses committed vault files and skills.

## Quick start

1. **Set up a VPS.** A $4 DigitalOcean droplet is enough. This is where git runs and Syncthing lives.

2. **Create a GitHub repository.** Make a new private repo for each vault and give the VPS push access.

3. **Install Corpus.** Clone this repo onto the VPS.

4. **Set environment variables.** Fill in your credentials and secrets.

5. **Initialize a vault.** Run the bootstrap script with your vault's GitHub URL. It sets up the directory structure and pushes an initial commit.

6. **Connect the vault to Syncthing.** Start Syncthing on the VPS and share the vault folder with your devices. A cron job keeps git in sync automatically.

7. **Connect to Claude Code.** Open the vault in Claude Code on the VPS or any synced device. The bootstrapped context and skill files give Claude what it needs to work with your vault.

8. **Basic usage workflow.** Chat with Claude Code in the cloud from any device — it reads and updates the vault directly. Syncthing keeps the vault in sync so changes are reflected everywhere. Editing notes in Obsidian on your devices is also supported.

See [docs/setup-and-operations.md](docs/setup-and-operations.md) for detailed instructions, commands, and troubleshooting.

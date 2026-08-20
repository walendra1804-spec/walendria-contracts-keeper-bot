"""
install_claude_key.py — one-shot lockdown of a fresh VPS.

Purpose. When a VPS provider hands over a new box with a seller-issued temporary root password,
this script does three things in one interactive run:

  1. Installs the Claude working-machine SSH public key into /root/.ssh/authorized_keys, so
     future access uses key auth and does not require typing the password again.
  2. Changes the root password to one only the user knows, killing the seller-known credential.
  3. Verifies key auth actually works before exiting, so a broken install does not silently
     leave you locked out.

The two passwords (the seller's temporary one and the user's new one) are entered locally via
getpass; they are never on the command line, never echoed, never logged. Claude never sees
them - the script runs in the user's own shell and the values live only in that process.

Usage. Windows cmd or PowerShell:

    pip install paramiko
    python D:\\walendria-contracts\\deploy\\install_claude_key.py

To point at a different host/port than the current default, pass them positionally:

    python install_claude_key.py 159.223.70.83 22

Probe before running: a fresh box sometimes answers ping while sshd is not up yet, which shows
as a connect timeout here and is NOT a wrong password. Box #2 (203.175.125.140) failed exactly
that way and had to be refunded.

After a green run, update D:\\vps-access-for-ai.md with the new IP and the note that the
password is now user-only. The seller-known password is dead.
"""

import getpass
import sys
from pathlib import Path

try:
    import paramiko
except ImportError:
    print("ERROR: paramiko not installed.")
    print("Run this first, then re-run the script:")
    print("    pip install paramiko")
    sys.exit(1)


# Defaults for the box handed over on 2026-08-18. Override on the command line if the provider
# rotates the IP or changes the SSH port.
DEFAULT_HOST = "203.175.125.140"
DEFAULT_PORT = 22054
USER = "root"

# The pair of files created by ssh-keygen on the working machine on 2026-07-14. The private key
# is what Claude uses to SSH in; the public key is what gets appended to authorized_keys on the
# VPS. Both must be present for the verify step to succeed.
PRIVKEY_PATH = Path.home() / ".ssh" / "id_walendria_vps"
PUBKEY_PATH = PRIVKEY_PATH.with_suffix(".pub")


def prompt_new_password() -> str:
    """Ask twice and confirm they match. Refuses empty; warns on short."""
    while True:
        new_pw = getpass.getpass("New root password: ")
        if not new_pw:
            print("  Empty. Try again.")
            continue
        new_pw2 = getpass.getpass("New root password (confirm): ")
        if new_pw != new_pw2:
            print("  Did not match. Try again.")
            continue
        if len(new_pw) < 12:
            reply = input(f"  Only {len(new_pw)} chars. Use anyway? [y/N] ").strip().lower()
            if reply != "y":
                continue
        return new_pw


def main() -> None:
    host = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_HOST
    port = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_PORT

    # Load pubkey up front. Failing here saves the user typing two passwords for nothing.
    if not PUBKEY_PATH.exists():
        print(f"ERROR: public key not found at {PUBKEY_PATH}")
        print("Expected the .pub file next to the private key id_walendria_vps.")
        sys.exit(1)
    pubkey = PUBKEY_PATH.read_text().strip()
    if not pubkey.startswith("ssh-"):
        print(f"ERROR: {PUBKEY_PATH} does not look like an SSH public key.")
        sys.exit(1)
    if not PRIVKEY_PATH.exists():
        print(f"ERROR: private key not found at {PRIVKEY_PATH}")
        print("Cannot verify key auth after install without the private half.")
        sys.exit(1)

    print(f"Target: {USER}@{host}:{port}")
    print("Nothing you type below is shown or logged.")
    print()

    print("Enter the TEMPORARY password given by the VPS seller.")
    initial_pw = getpass.getpass("Seller's temporary password: ")
    if not initial_pw:
        print("ERROR: empty password")
        sys.exit(1)

    print()
    print("Enter the NEW password. Keep this safe; only you will know it.")
    new_pw = prompt_new_password()

    # ---- [1/4] connect with seller's password ----
    print()
    print(f"[1/4] Connecting to {host}:{port} with the seller's password...")
    client = paramiko.SSHClient()
    # First contact with a fresh box has no known host key. AutoAddPolicy accepts whatever the
    # server presents on this one connection; the paranoid alternative (verifying the fingerprint
    # out of band with the provider) is out of scope for this script.
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(
            hostname=host,
            port=port,
            username=USER,
            password=initial_pw,
            allow_agent=False,
            look_for_keys=False,
            timeout=20,
        )
    except paramiko.AuthenticationException:
        print("ERROR: authentication failed. Check the temporary password and try again.")
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: connection failed: {e}")
        sys.exit(1)
    print("      OK")

    # ---- [2/4] install pubkey ----
    print("[2/4] Installing SSH public key into /root/.ssh/authorized_keys...")
    setup = (
        "mkdir -p /root/.ssh && "
        "chmod 700 /root/.ssh && "
        "touch /root/.ssh/authorized_keys && "
        "chmod 600 /root/.ssh/authorized_keys"
    )
    stdin, stdout, stderr = client.exec_command(setup)
    if stdout.channel.recv_exit_status() != 0:
        print(f"ERROR: could not set up /root/.ssh: {stderr.read().decode(errors='replace')}")
        client.close()
        sys.exit(1)

    # Read existing keys to avoid duplicate append (rerunning this script should be a no-op).
    stdin, stdout, stderr = client.exec_command("cat /root/.ssh/authorized_keys")
    existing = stdout.read().decode("utf-8", errors="replace")
    if pubkey in existing:
        print("      key already present, skipping append")
    else:
        # tee via stdin so we do not have to shell-escape the key contents.
        stdin, stdout, stderr = client.exec_command("tee -a /root/.ssh/authorized_keys > /dev/null")
        stdin.channel.send(pubkey + "\n")
        stdin.channel.shutdown_write()
        if stdout.channel.recv_exit_status() != 0:
            print(f"ERROR: appending key failed: {stderr.read().decode(errors='replace')}")
            client.close()
            sys.exit(1)
        print("      appended")

    # ---- [3/4] rotate the root password ----
    print("[3/4] Changing root password (seller's password will be dead after this)...")
    # chpasswd reads "user:password" pairs from stdin. Piping this way keeps the password out of
    # ps output, shell history, and any command-line log.
    stdin, stdout, stderr = client.exec_command("chpasswd")
    stdin.channel.send(f"{USER}:{new_pw}\n")
    stdin.channel.shutdown_write()
    exit_code = stdout.channel.recv_exit_status()
    if exit_code != 0:
        err = stderr.read().decode("utf-8", errors="replace")
        print(f"ERROR: chpasswd failed (exit {exit_code}): {err}")
        client.close()
        sys.exit(1)
    print("      OK")
    client.close()

    # ---- [4/4] verify key auth actually works ----
    # If this step is skipped and something went wrong at step 2, we would leave the box in a
    # state where the seller password is dead AND Claude cannot get in. Verifying with the
    # freshly-installed key while we still know the old password is dead is the safety net.
    print("[4/4] Verifying key auth works with the newly installed key...")
    verify = paramiko.SSHClient()
    verify.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        verify.connect(
            hostname=host,
            port=port,
            username=USER,
            key_filename=str(PRIVKEY_PATH),
            allow_agent=False,
            look_for_keys=False,
            timeout=20,
        )
    except paramiko.AuthenticationException:
        print("ERROR: key auth failed after install. Something went wrong at step 2.")
        print("       You still have the NEW password (which you just set) as the way in.")
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: verify connection failed: {e}")
        sys.exit(1)

    stdin, stdout, stderr = verify.exec_command("hostname && whoami && uptime")
    print("      Response from VPS:")
    for line in stdout.read().decode("utf-8", errors="replace").splitlines():
        print(f"        {line}")
    verify.close()

    print()
    print("=" * 60)
    print("SUCCESS")
    print("  - Seller's temporary password is now DEAD")
    print("  - Only you know the new password (write it down / put in a manager)")
    print("  - Claude can SSH in via id_walendria_vps key, no password needed")
    print("=" * 60)
    print()
    print(f"Update D:\\vps-access-for-ai.md with:")
    print(f"    IP:   {host}")
    print(f"    Port: {port}")


if __name__ == "__main__":
    main()

# Activation script that creates the direnv-sandbox test project directories.
#
# zshrcWorkaround: create a dummy ~/.zshrc to prevent zsh's new-user-install
# wizard from blocking. Needed when HM doesn't manage .zshrc (NixOS-module
# tests), not needed when HM owns ~/.zshrc.
{ lib, shell }:
{ zshrcWorkaround ? false }:
{
  deps = [ "users" ];
  text = ''
    mkdir -p /home/alice/project/subdir
    echo 'export SANDBOX_TEST=hello' > /home/alice/project/.envrc
    chown -R alice:users /home/alice/project

    mkdir -p /home/alice/project2
    echo 'export SANDBOX_TEST2=world' > /home/alice/project2/.envrc
    chown -R alice:users /home/alice/project2

    mkdir -p /home/alice/project-denied
    echo 'export SANDBOX_TEST_DENIED=evil' > /home/alice/project-denied/.envrc
    chown -R alice:users /home/alice/project-denied

    mkdir -p /home/alice/project-notallowed
    echo 'export SANDBOX_TEST_NOTALLOWED=nope' > /home/alice/project-notallowed/.envrc
    chown -R alice:users /home/alice/project-notallowed

    mkdir -p /home/alice/.cache
    echo "bind-works" > /home/alice/.cache/bind-test-file
    chown -R alice:users /home/alice/.cache

    # Symlinked project: real dir is ~/synced/projects/symtest,
    # accessed via ~/projects-link/symtest
    mkdir -p /home/alice/synced/projects/symtest
    echo 'export SANDBOX_TEST_SYM=symlinked' > /home/alice/synced/projects/symtest/.envrc
    chown -R alice:users /home/alice/synced
    ln -sfn /home/alice/synced/projects /home/alice/projects-link
    chown -h alice:users /home/alice/projects-link
  ''
  + lib.optionalString (zshrcWorkaround && shell == "zsh") ''
    touch /home/alice/.zshrc
    chown alice:users /home/alice/.zshrc
  '';
}

# knsk - Kubernetes namespace killer

This script is aimed to kill namespaces that are stuck in Terminating mode after you try to delete them. Just calling this script without flags, it shows you the possible problems that put your namespace in forever terminating mode.

It automates the tips by https://github.com/alvaroaleman in https://github.com/kubernetes/kubernetes/issues/60807#issuecomment-524772920

If it doesn't work for you, please, let me know. It is hard to force namespace in Terminating mode just to test it.

### Do you want a backup first? 

Just call the script to make a backup of all cluster in YAML format, ordered by folder:

     curl -s https://raw.githubusercontent.com/thyarles/knsk/master/backup-yaml.sh | bash 
     wget -q https://raw.githubusercontent.com/thyarles/knsk/master/backup-yaml.sh -O - | bash 

### Basic usage
     curl -s https://raw.githubusercontent.com/thyarles/knsk/master/knsk.sh | bash 
     wget -q https://raw.githubusercontent.com/thyarles/knsk/master/knsk.sh -O - | bash 
     
In this mode, this script only shows the possible causes that put your namespaces in **Terminating** mode. If you want this script to try to fix the mess, clone this repository, set the execution bit to the `knsk.sh` script doing `chmod +x knsk.sh` and look at advanced options by typing `./knsk.sh --help`.

Just to see what are the possible commands to solve the problem by yourself, use the dry-run mode like

     ./knsk.sh --dry-run --delete-all --force

### Options
    knsk.sh [options]

    --dry-run             Show what will be executed instead of execute it (use with '--delete-*' options)
    --skip-tls            Set --insecure-skip-tls-verify on kubectl call
    --delete-api          Delete broken API found in your Kubernetes cluster
    --delete-resource     Delete resources found in your stuck namespaces
    --delete-all          Delete resources of stuck namespaces and broken API
    --force               Force deletion of stuck namespaces even if a clean deletion fail
    --port {number}       Up kubectl proxy on this port, default is 8765
    --timeout {number}    Max time (in seconds) to wait for Kubectl commands
    --no-color            All output without colors (useful for scripts)
    -h --help             Show this help

### Issues

If **knsk** doesn't meet your needs, feel free to open an issue, I'll be happy to help.

Also, you can try the new [nsmurder](https://github.com/achetronic/nsmurder). I've never used it and as far as I know it was made in [Go](https://golang.com). If you are serious about security, you should carefully examine the source code, including (source code of dependencies) before using it. I believe in the developer who made it, he's a nice guy, but I don't believe in the developers of the dependencies the project needs.

### Atention

As Kubernetes progressed and those problems we used to have on versions before `1.20` doesn't exist anymore, this repository will be archived soon. Thanks you all that helped make the `OPS` life a little better making this code reliable and saving us tons of time.

# knsk - Kubernetes namespace killer

This tool is aimed to kill namespaces that stuck in Terminating mode after you try to delete it.

### Just call the script on an host that manage your Kubernetes (kubectl configured)

#### with CURL
     curl -s https://raw.githubusercontent.com/thyarles/knsk/master/knsk.sh | sh 

#### with WGET
     wget -q https://raw.githubusercontent.com/thyarles/knsk/master/knsk.sh -O - | sh 

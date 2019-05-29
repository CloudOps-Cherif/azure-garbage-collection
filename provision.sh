#!/bin/bash

PWD=`pwd`
random() { size=$1; echo -n `date +%s%N | sha256sum | base64 | head -c $size`;}

while [[ $# -gt 0 ]]
do
    key="$1"
    shift

    case $key in
        -n|--name)
            NAME="$1"
            shift
        ;;
        -l|--location)
            LOCATION="$1"
            shift
        ;;
        *)
            echo "Unknown parameter: $key"
            usage
        ;;
    esac
done


RANDOMBASE="`random 5`"
SUBSCRIPTIONID="`az account show --query id -o tsv`"
SUBSCRIPTION_RESOURCE_ID="/subscriptions/$SUBSCRIPTIONID"

if [ ! -f env.sh ]; then
    echo "#!/bin/bash

NAME='`basename "$PWD"`'
LOCATION=\"westus2\"
RANDOMBASE=\"$RANDOMBASE\"
RANDOMBASE16CHAR=\"`random 16`\"
STORAGEBASENAME=\"`echo -n $NAME | head -c 15`$RANDOMBASE\"
SUBSCRIPTIONID=\"$SUBSCRIPTIONID\"
SUBSCRIPTION_RESOURCE_ID=\"$SUBSCRIPTION_RESOURCE_ID\"
TENANTID=`az  account show --query tenantId -o tsv`
" > env.sh
fi


source env.sh

usage() {
    echo "Usage: `basename "$0"` [--name $NAME] [--location $LOCATION]"
    exit 1
}





echo "This will provision the following resources: "
echo "AppRegistration (default)"
echo "ResourceGroup (default)"
echo "StorageAccount (default)"
echo "FunctionApp (default)"

DEFAULT_APPLICATION_IDENTIFIER_URI="https://$NAME-$RANDOMBASE.azurewebsites.net/"
DEFAULT_APPLICATION_PASSWORD="@$RANDOMBASE16CHAR!@123001"
DEFAULT_RESOURCE_GROUP="$NAME"
DEFAULT_RESOURCE_GROUP_RESOURCE_ID="$SUBSCRIPTION_RESOURCE_ID/resourceGroups/$DEFAULT_RESOURCE_GROUP"
DEFAULT_STORAGE_ACCOUNT="`echo "$STORAGEBASENAME" | sed -e 's/-//g' | sed -E 's/^(.*)$/\L\1/g' | head -c 20`def"
DEFAULT_STORAGE_ACCOUNT_RESOURCE_ID="$DEFAULT_RESOURCE_GROUP_RESOURCE_ID/providers/Microsoft.Storage/storageAccounts/$DEFAULT_STORAGE_ACCOUNT"
DEFAULT_FUNCTIONAPP="$NAME-$RANDOMBASE"
DEFAULT_FUNCTIONAPP_HOSTNAME="https://$DEFAULT_FUNCTIONAPP.azurewebsites.net"

echo "Creating App Registration $DEFAULT_APPLICATION_IDENTIFIER_URI"
echo "[{
    'resourceAppId': '00000002-0000-0000-c000-000000000000',
    'resourceAccess': [ {
        'id': '311a71cc-e848-46a1-bdf8-97ff7156d8e6',
        'type': 'Scope'
        } ]
    }]" > app-registration-manifest.tmp.json
DEFAULT_APPLICATION_ID=`az ad app create --identifier-uris $DEFAULT_APPLICATION_IDENTIFIER_URI --available-to-other-tenants false --reply-urls $DEFAULT_FUNCTIONAPP_HOSTNAME/.auth/login/aad/callback --display-name DEFAULT_APPLICATION_IDENTIFIER_URI --password "$DEFAULT_APPLICATION_PASSWORD" --required-resource-access app-registration-manifest.tmp.json --query "appId" -o tsv`
echo "Creating resource group $DEFAULT_RESOURCE_GROUP"
az group create --name $DEFAULT_RESOURCE_GROUP --location $LOCATION --query "properties.provisioningState" -o tsv
echo "Creating storage account $DEFAULT_STORAGE_ACCOUNT"
az storage account create --name $DEFAULT_STORAGE_ACCOUNT --kind StorageV2 --sku Standard_LRS --location $LOCATION -g $DEFAULT_RESOURCE_GROUP --https-only true --query "provisioningState" -o tsv
DEFAULT_STORAGE_ACCOUNT_CONNECTION_STRING=`az storage account show-connection-string -g $DEFAULT_RESOURCE_GROUP -n $DEFAULT_STORAGE_ACCOUNT --query connectionString -o tsv`



echo "Creating functionapp $DEFAULT_FUNCTIONAPP"
az functionapp create -g $DEFAULT_RESOURCE_GROUP --consumption-plan-location $LOCATION --name $DEFAULT_FUNCTIONAPP --storage-account $DEFAULT_STORAGE_ACCOUNT --query "state" -o tsv
az functionapp config appsettings set --name $DEFAULT_FUNCTIONAPP -g $DEFAULT_RESOURCE_GROUP --settings SUBSCRIPTION=$SUBSCRIPTION_RESOURCE_ID DEFAULT_EXPIRY_DAYS=14 > /dev/null
echo "Configuring easy auth for functionapp $DEFAULT_FUNCTIONAPP"
az webapp auth update --ids $DEFAULT_RESOURCE_GROUP_RESOURCE_ID/providers/Microsoft.Web/sites/$DEFAULT_FUNCTIONAPP --action LoginWithAzureActiveDirectory --enabled true --aad-client-id $DEFAULT_APPLICATION_ID --aad-client-secret "$DEFAULT_APPLICATION_PASSWORD" --aad-token-issuer-url https://login.microsoftonline.com/$TENANTID/  > /dev/null
echo "Configuring identity for functionapp $DEFAULT_FUNCTIONAPP with contributor access to scope $SUBSCRIPTIONID. Principal id:"
az functionapp identity assign --name $DEFAULT_FUNCTIONAPP --resource-group $DEFAULT_RESOURCE_GROUP --role contributor --scope "$SUBSCRIPTIONID" --query principalId -o tsv
echo "Deploying function app $DEFAULT_FUNCTIONAPP"
func azure functionapp publish $DEFAULT_FUNCTIONAPP

echo "Generating cleanup script"
echo "#!/bin/bash
echo 'Removing app registration $DEFAULT_APPLICATION_IDENTIFIER_URI'
az ad app delete --id $DEFAULT_APPLICATION_IDENTIFIER_URI
echo 'Removing resource group $DEFAULT_RESOURCE_GROUP'
az group delete --name $DEFAULT_RESOURCE_GROUP --yes


rm env.sh
" > cleanup.sh
chmod +x cleanup.sh
        
echo "                 App id: $DEFAULT_APPLICATION_ID"
echo "                App URI: $DEFAULT_APPLICATION_IDENTIFIER_URI"
echo "           App password: $DEFAULT_APPLICATION_PASSWORD"
echo "    Resource group name: $DEFAULT_RESOURCE_GROUP"
echo "  Storage account (def): $DEFAULT_STORAGE_ACCOUNT"
echo "      Storage key (def): $DEFAULT_STORAGE_ACCOUNT_CONNECTION_STRING"
echo "          Function Name: $DEFAULT_FUNCTIONAPP"
echo "           Function URL: $DEFAULT_FUNCTIONAPP_HOSTNAME"


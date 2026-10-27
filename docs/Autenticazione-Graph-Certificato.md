# Microsoft Graph: applicazione dedicata e certificato

Disponibile da Assistente IT 1.0.16. Il sistemista crea e autorizza l'applicazione in Entra ID; sul PC viene usato il certificato installato nello store Windows. Non viene aperta la finestra di login Microsoft in questa modalita.

Per gestire le operazioni in base ai ruoli del tecnico, da 1.0.17 e disponibile [Accesso delegato (app dedicata)](Autenticazione-Graph-Delegata.md), che richiede solo Tenant ID e Client ID e non usa il certificato. Le istruzioni seguenti riguardano invece la modalita applicativa.

## Dati da ricevere dal sistemista

- Directory (Tenant) ID e Application (Client) ID, entrambi GUID.
- Certificato con la chiave privata, installato o distribuito sul PC, e relativa impronta (Thumbprint). Il solo CER pubblico non permette all'app di autenticarsi.
- Archivio previsto: `Cert:\CurrentUser\My` oppure `Cert:\LocalMachine\My`. Per LocalMachine l'utente che esegue Assistente IT deve avere accesso alla chiave privata.

Il sistemista registra la parte pubblica del certificato nell'app Entra. Il PFX e la sua eventuale password si gestiscono localmente con il sistemista: non vanno inseriti nella configurazione JSON, nel repository o nel pacchetto di Assistente IT. L'app memorizza soltanto Tenant ID, Client ID, impronta e scelta dello store.

## Permessi Microsoft Graph

Selezionare **Application permissions / Autorizzazioni applicazione**, con **consenso amministratore**. Per tutte le funzioni attuali:

| Funzione | Permesso applicativo |
|---|---|
| Lettura ed eliminazione delle registrazioni Entra | `Device.ReadWrite.All` |
| Lettura ed eliminazione dei dispositivi Intune | `DeviceManagementManagedDevices.ReadWrite.All` |
| Lettura delle password di recupero BitLocker | `BitlockerKey.Read.All` |

Per una distribuzione di sola consultazione, i primi due possono essere `Device.Read.All` e `DeviceManagementManagedDevices.Read.All`: le eliminazioni saranno rifiutate dalle API. `BitlockerKey.ReadBasic.All` non sostituisce `BitlockerKey.Read.All` quando serve il valore della password di recupero.

I permessi sono dell'applicazione, usati attraverso la sua chiave privata. `Directory.AccessAsUser.All` appartiene al login delegato precedente e non va configurato come permesso applicativo per questo flusso. AD continua a usare le credenziali Windows e GLPI i token gia configurati: il certificato Graph non assegna diritti su AD o GLPI.

## Attivazione nel programma

1. Installare il certificato con chiave privata nello store concordato e verificare la sua validita.
2. Chiudere Computer Explorer. Nella schermata principale aprire **Impostazioni > Microsoft Graph**.
3. Selezionare **Applicazione con certificato**, inserire Tenant ID, Client ID e impronta, scegliere lo store e salvare.
4. Riaprire il modulo e provare una ricerca e **Cerca chiavi** su un PC noto. Solo dopo la verifica dei permessi e del backup GLPI usare le eliminazioni.

Prima della consegna del certificato si possono conservare Tenant/Client ID lasciando selezionato **Accesso utente (app Microsoft)**; in questa modalita gli ID non selezionano l'app dedicata. Per il login del tecnico tramite l'app aziendale scegliere invece **Accesso delegato (app dedicata)** e configurare i permessi Delegati come descritto nella guida collegata. La modalita con certificato richiede i tre identificativi completi; il certificato non deve essere presente per salvare la configurazione, ma deve essere disponibile quando ci si collega con questa modalita.

La configurazione locale comprende:

```json
"Graph": {
  "AuthenticationMode": "Certificate",
  "TenantId": "11111111-1111-4111-8111-111111111111",
  "ClientId": "22222222-2222-4222-8222-222222222222",
  "CertificateThumbprint": "AABBCCDDEEFF00112233445566778899AABBCCDD",
  "CertificateStore": "CurrentUser"
}
```

Gli identificativi dell'esempio sono fittizi. Le configurazioni gia installate senza la sezione Graph restano interattive; gli aggiornamenti non impostano automaticamente un certificato.

## Verifiche ed errori

Il programma seleziona esattamente il certificato dello store richiesto, controlla impronta, chiave privata e date di validita e passa l'oggetto X509 a `Connect-MgGraph` con tenant/client espliciti, ambiente Global e contesto Process. La sessione deve corrispondere alla configurazione; un'altra app, un altro tenant o un altro certificato non vengono riutilizzati. I permessi vengono verificati dalle API, senza richiedere ambiti delegati o avviare un login utente alternativo in caso di errore.

Certificato assente, scaduto o pubblico senza chiave privata: correggere installazione e configurazione con il sistemista. Autenticazione non riuscita: verificare corrispondenza tra app, tenant e parte pubblica registrata, oltre all'accesso alla chiave privata. HTTP 403 sulle operazioni: verificare i permessi applicativi e il consenso amministratore in Entra.

Le prove automatiche usano identita simulate, la GUI Windows e un certificato di test generato e rimosso nello store CurrentUser. Non interrogano il tenant aziendale. La verifica reale e possibile solo dopo la consegna e autorizzazione del certificato aziendale.

## Documentazione Microsoft

- [Autenticazione Graph PowerShell con certificato](https://learn.microsoft.com/en-us/powershell/microsoftgraph/authentication-commands)
- [Eliminazione dispositivo Entra e permessi](https://learn.microsoft.com/en-us/graph/api/device-delete)
- [Eliminazione dispositivo Intune e permessi](https://learn.microsoft.com/en-us/graph/api/intune-devices-manageddevice-delete)
- [Lettura delle chiavi BitLocker](https://learn.microsoft.com/en-us/graph/api/bitlockerrecoverykey-get)

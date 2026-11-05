# Accesso comune e autorizzazioni dei moduli

**Stato accesso** mostra l'account Microsoft e l'esito delle letture.
**Accesso** è nella barra inferiore, accanto a Impostazioni, Cartella dati e
Cerca aggiornamenti.

## Flusso

1. Dopo l'aggiornamento a 1.3.0, premere **Accesso** una volta, completare il
   login Microsoft e confermare. Il wrapper salva il riferimento all'account
   confermato nella cartella dati personale.
2. Alle aperture successive, il wrapper prova a ripristinare la sessione in
   background e abilita i moduli per i quali le letture richieste riescono.
3. Usare **Accesso** se il pannello chiede di rinnovare la sessione, per
   esempio dopo una richiesta di MFA o un cambio di app o tenant.

Microsoft Graph PowerShell e Windows gestiscono la cache dei token per il
profilo utente. Il file `Config/graph-session.json` contiene solo i dati
dell'account e della registrazione necessari a selezionare la sessione.
Il ripristino usa acquisizione silenziosa anche per il rinnovo dei token
durante le richieste. L'autenticazione interattiva parte dal pulsante Accesso.

I moduli condividono la sessione verificata tramite runspace STA nello stesso
processo. Chiudere i moduli prima di cambiare accesso o impostazioni.

## Permessi e modalità

Il manifest dichiara gli ambiti e i requisiti di lettura e scrittura per
ogni modulo. Un modulo può richiedere tutte le sue letture per aprirsi.
Il wrapper mostra **Sola lettura** o **Lettura e scrittura (ambiti concessi)**
sulla scheda del modulo.

| Lettura | Richiesta di verifica |
| --- | --- |
| Entra ID | Un dispositivo, con il solo ID |
| Intune | Un dispositivo gestito, con il solo ID |
| Gruppi | Un gruppo, con il solo ID |
| Appartenenze dell'account | Controllo quando il manifest configura regole di gruppo |

Gli esiti delle letture indicano la risposta effettiva del servizio.
BitLocker e scritture sono abilitati in base agli ambiti e ai prerequisiti.
I servizi verificano i diritti effettivi al momento dell'operazione.

## Gruppi facoltativi per modulo

Per attribuire accessi diversi ai colleghi anche quando l'app ha gli stessi ambiti, un modulo puo dichiarare gruppi Entra separati. Identificativi fittizi:

```json
"ReadGroupIds": ["33333333-3333-4333-8333-333333333333"],
"WriteGroupIds": ["44444444-4444-4444-8444-444444444444"]
```

- Membro del gruppo lettori: sola lettura, anche se il token dell'app contiene ambiti di scrittura.
- Membro del gruppo operatori: scrittura soltanto se sono disponibili anche i requisiti Graph richiesti.
- Non assegnato: modulo disabilitato.
- Appartenenze non verificabili: modulo disabilitato.

Un operatore puo aprire il modulo senza essere anche nel gruppo lettori. Se e configurato soltanto un gruppo lettori, nessuno riceve accesso in scrittura tramite questa regola. Senza gruppi configurati si applicano i soli requisiti di ambito dichiarati. I gruppi non vengono creati ne assegnati dall'app: il sistemista deve concordare gli accessi e mantenere coerenti le autorizzazioni dei servizi.

Le appartenenze dell'utente autenticato vengono lette con `GET /me/transitiveMemberOf?$select=id`, comprese quelle transitive. Serve il consenso `User.Read` o un ambito compatibile; non si richiedono automaticamente autorizzazioni Directory piu ampie. La verifica gruppi viene eseguita soltanto quando almeno un modulo configura una regola di gruppo. La configurazione attuale di Computer Explorer non contiene gruppi aziendali inventati o preassegnati.

## Modalita di autenticazione

**Accesso delegato (app dedicata)** usa Tenant ID, Client ID e `https://graph.microsoft.com/.default`. Se esiste gia un consenso Graph per quell'app e utente, Microsoft restituisce gli ambiti concessi. Non si aggiungono consensi durante l'uso dei moduli. Se nessun consenso esiste, Microsoft puo richiedere l'approvazione iniziale dell'amministratore; un errore o un annullamento mantiene i moduli disabilitati.

**Accesso utente (app Microsoft)** mantiene il metodo precedente e richiede gli ambiti del catalogo nel solo accesso iniziale, eliminando le richieste ridondanti quando un ambito piu ampio copre gia un requisito. Non si passa automaticamente da un'app all'altra per aggirare un consenso mancante.

La cancellazione Entra resta supportata con `Directory.AccessAsUser.All` e i relativi diritti. Se il consenso manca, la scelta Entra e indisponibile; gli altri accessi autorizzati rimangono utilizzabili. La modalita con certificato e stata rimossa in 1.0.18. Eventuali certificati nello store Windows non vengono modificati.

## Finestra e aggiornamenti

Finestre e collegamenti usano l'identita Windows **AssistenteIT.Desktop** e l'icona del programma. PowerShell resta il motore interno; il launcher non e stato trasformato in un nuovo host eseguibile. Lo stile Windows viene inizializzato prima delle finestre.

**Cerca aggiornamenti** avvia il controllo. Quando una versione e disponibile compare **Installa aggiornamento**. L'installazione conserva configurazione e credenziali personali e richiede la chiusura dei moduli.

Gli errori della ricerca chiavi distinguono ricerca Intune, Azure AD Device ID, elenco metadati, lettura password e risposta non valida. Quando disponibili mostrano stato HTTP, codice Graph e request-id; non riportano corpi di risposta, token o password. Un HTTP 400 non viene presentato come prova di un ruolo mancante.

[Cache di Graph PowerShell](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands) · [Acquisizione senza interazione](https://learn.microsoft.com/dotnet/api/azure.identity.interactivebrowsercredentialoptions.disableautomaticauthentication)

Riferimenti: [AppUserModelID](https://learn.microsoft.com/en-us/windows/win32/shell/appids), [scope .default](https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc#the-default-scope), [appartenenze dell'utente](https://learn.microsoft.com/en-us/graph/api/user-list-transitivememberof).


## Ricerca GLPI per seriale e conferma senza archivio (1.0.21)

Quando Intune fornisce un seriale hardware valido, GLPI viene interrogato per quel seriale e l'asset e associato al PC anche se il nome GLPI e diverso. Il nome GLPI originale resta visibile nei dettagli. Le schede omonime con seriale diverso non sono associate al PC Intune; senza seriale valido si conserva la ricerca per nome. I seriali generici del firmware non sono usati come identita. La ricerca per seriale usa il campo scoperto nelle opzioni GLPI, controlli esatti sul dettaglio e criteri suddivisi in lotti nella stessa sessione.

La ricerca iniziale delle quattro fonti rimane parallela. Dopo la lettura Intune, un secondo passaggio GLPI integra le schede trovate per seriale; la ricerca non e completa finche anche questo passaggio non termina. Un errore non viene presentato come assenza del PC.

Se per il seriale Intune (o per il nome, quando manca il seriale) risultano zero o piu schede GLPI attive, la cancellazione mostra un avviso e una seconda conferma esplicita per i soli PC interessati. **Scarica chiavi** salva un file di testo con computer, seriale, ID e password di recupero; **Stampa chiavi** apre la scelta della stampante e gestisce report su piu pagine. La copia e facoltativa: l'operatore puo confermare il rischio di perdita senza crearla. Le password sono rilette soltanto su richiesta di copia/stampa e non compaiono nell'anteprima o negli eventi di avanzamento.

La conferma senza GLPI non sceglie una scheda a caso e non scrive Note GLPI. Gli altri PC del lotto conservano il backup verificato. Errori di recupero, identita cambiate, chiavi cambiate e oggetti AD protetti non vengono ignorati. Il backend richiede i nomi esatti dei PC confermati e ripete i controlli prima delle cancellazioni. **Archivia BitLocker** continua a richiedere una scheda GLPI univoca; una conferma di perdita non viene trattata come archiviazione riuscita. Le Note GLPI preesistenti restano inalterate.

## Diagnostica durante la lettura delle chiavi

Dalla 1.0.22 **Leggi chiavi** mostra le singole fasi della richiesta e offre **Copia diagnostica**. Sono riportati anche AuthType, Tenant ID, Client ID e presenza degli scope pertinenti nel processo che esegue realmente la lettura, senza token o password. La diagnostica conserva gli errori del SDK in formato HTTP e distingue gli errori locali di identificativo, raccolta o password. Il test iniziale continua a leggere soltanto metadati e non certifica l'accesso alla password.

La colonna **Identita AD/Entra** controlla soltanto i dispositivi hybrid joined tramite `deviceId`/`ObjectGUID`, riconosce i nomi AD differenti e richiede un consenso specifico prima di eliminare i PC con una discordanza provata. Registered e joined cloud restano non applicabili. Le letture usano i permessi gia disponibili.

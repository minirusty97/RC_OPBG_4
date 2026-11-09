# Computer Explorer, prova AD su base 1.3.3

Estrarre il pacchetto `Assistente-IT-1.3.3-5DC-Test-AD.zip` e avviare
`AssistenteIT-Test-AD.exe` dalla cartella estratta. La finestra indica
**Test ricerca AD** e offre Computer Explorer in sola consultazione.
L'account Microsoft salvato viene verificato dal wrapper. **Accesso**
resta disponibile se la sessione deve essere rinnovata.

Al primo avvio la prova copia le impostazioni, il riferimento all'account
Microsoft e il file DPAPI delle credenziali GLPI nel profilo Windows corrente,
in `%LOCALAPPDATA%\AssistenteIT-TestAD`. La cifratura DPAPI delle
credenziali GLPI resta legata a quel profilo. L'archivio ZIP contiene
soltanto i file del programma. La prova gira fuori dal canale OTA.

## Confronto

1. In Computer Explorer lasciare selezionata solo la fonte **AD**.
2. Cercare con **AD parallelo (5 DC)**, già selezionato. Per il confronto,
   ripetere la stessa ricerca deselezionandolo.
3. Nella scheda **Stato fonti e orari** annotare il tempo di AD, i DC verificati e
   gli eventuali ritentativi. I risultati vanno confrontati anche come
   numero di nomi e come copertura AD. Una replica non verificabile
   è distinta da una risposta senza risultati.
4. Ripetere con le fonti che si usano di solito e la stessa impostazione
   **Rileggi cloud** per entrambe le ricerche. Il tempo per fonte
   indica quale lettura determina l'attesa complessiva.

La modalità sequenziale è il riferimento della 1.3.3. Con cinque DC
configurati la modalità parallela li avvia insieme, ciascuno in un
processo Windows PowerShell separato. Il DC principale viene accodato
per primo e resta l'unico riferimento per il confronto GUID Hybrid e
Intune. Il filtro LDAP per nome, nome DNS e sAMAccountName resta comune
alle due modalità.

Ogni tentativo parallelo ha 30 secondi, incluso l'avvio del lettore.
I DC in errore vengono ritentati una volta, uno alla volta, dopo la prima
lettura degli altri DC. **Interrompi** chiude i processi AD attivi.

## Log di ricerca

**Apri log** apre in Blocco note il file dell'ultima ricerca, anche dopo
un'interruzione. I file vengono conservati in
`%LOCALAPPDATA%\AssistenteIT-TestAD\Logs\ComputerExplorer`.

Ogni riga riporta un evento JSON con ora UTC. Gli eventi AD indicano DC,
PID e tentativo. Il log distingue lancio, caricamento del modulo AD,
inizio ed esito di `Get-ADComputer`, validazione, ricezione della risposta,
timeout, interruzione e ritentativo. Riporta inoltre stato e durata delle
altre fonti selezionate. Gli errori contengono categoria, tipo e codice
quando disponibile. Il frammento cercato, i record dei computer, i token
e il testo libero delle eccezioni restano fuori dal log.

## Riferimenti del test

> Progetto INTUNE, repository minirusty97/RC_OPBG_4, ramo
> diagnostic/ad-parallelo. Leggi AGENTS.md e docs/Test-AD-Parallelo.md.
> Baseline 1.3.3. Confronta i tempi AD e complessivi, la copertura dei
> cinque DC e gli eventuali ritentativi, poi valuta l'integrazione.

I test usano cinque DC simulati, inclusi un timeout con ritentativo,
un errore ripetuto e l'annullamento durante cinque letture attive.
Le prestazioni e la connettività reali vanno misurate dalla postazione
del tecnico.

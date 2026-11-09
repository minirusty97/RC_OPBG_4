# Computer Explorer, prova AD su base 1.3.3

Estrarre il pacchetto `Assistente-IT-1.3.3-Test-AD.zip` e avviare
`AssistenteIT-Test-AD.exe` dalla cartella estratta. La finestra indica
**Test ricerca AD** e offre Computer Explorer in sola consultazione.
L'account Microsoft salvato viene verificato dal wrapper. **Accesso**
resta disponibile se la sessione deve essere rinnovata.

Al primo avvio la prova copia le impostazioni, il riferimento all'account
Microsoft e il file DPAPI delle credenziali GLPI nel profilo Windows corrente,
in `%LOCALAPPDATA%\AssistenteIT-TestAD`. La cifratura DPAPI delle
credenziali GLPI resta legata a quel profilo. L'archivio ZIP contiene
soltanto i file del programma. La stabile conserva la sua cartella dati
e il suo canale di aggiornamento.

## Confronto

1. In Computer Explorer lasciare selezionata solo la fonte **AD**.
2. Cercare lo stesso frammento con **AD parallelo (2 DC)** prima
   deselezionato e poi selezionato. Ripetere in ordine inverso per ridurre
   l'effetto della prima lettura.
3. Nella scheda **Stato fonti e orari** annotare il tempo di AD, i DC verificati e
   gli eventuali ritentativi. I risultati vanno confrontati anche come
   numero di nomi e come copertura AD. Una replica non verificabile
   è distinta da una risposta senza risultati.
4. Ripetere con le fonti che si usano di solito e la stessa impostazione
   **Rileggi cloud** per entrambe le ricerche. Il tempo per fonte
   indica quale lettura determina l'attesa complessiva.

La modalità sequenziale è il riferimento della 1.3.3. La modalità
parallela interroga al massimo due DC alla volta, con un processo Windows
PowerShell separato per ogni lettura. Il DC principale viene accodato
per primo e resta l'unico riferimento per il confronto GUID Hybrid e
Intune. Il filtro LDAP per nome, nome DNS e sAMAccountName resta comune
alle due modalità.

Ogni tentativo parallelo ha 30 secondi, incluso l'avvio del lettore.
Un errore riduce a uno i lettori successivi. I DC in errore vengono
ritentati una volta in sequenza dopo la prima lettura degli altri DC.
**Interrompi** chiude i processi AD attivi. La scheda Stato fonti e orari mostra il
tempo, l'esito e il motivo dell'eventuale primo errore.

## Riprendere in una nuova chat

> Progetto INTUNE, repository minirusty97/RC_OPBG_4, ramo
> diagnostic/ad-parallelo. Leggi AGENTS.md e docs/Test-AD-Parallelo.md.
> Baseline 1.3.3. Confronta i tempi AD e complessivi, la copertura dei
> cinque DC e gli eventuali ritentativi, poi valuta l'integrazione.

I test usano cinque DC simulati, incluso un lettore bloccato, un errore
ripetuto e un annullamento durante due letture. Le prestazioni e la
connettività reali vanno misurate dalla postazione del tecnico.

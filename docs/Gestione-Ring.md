# Gestione Ring Intune

Modulo derivato da `Assegna-PC-Orfani-Ring-Intune.ps1`, con accesso del wrapper,
operazioni asincrone, controlli di identita e consultazione GLPI condivisa.

## Selezione gruppi

Da Impostazioni → Ring Intune → Seleziona gruppi da Entra usare Carica gruppi
Entra. Serve prima Accesso dal wrapper con lettura dispositivi e gruppi
disponibili. La ricerca usa l'inizio del nome; il filtro vuoto legge tutti i
gruppi, con paginazione completa. Non apre un secondo accesso Microsoft.

- **Controlla**: il gruppo contribuisce a determinare se un PC e gia assegnato.
- **Modifica**: il gruppo puo ricevere PC e consentire rimozioni confermate, se statico,
  cloud, di sicurezza, non abilitato alla posta e non assegnabile a ruoli.
- **Etichetta**: nome breve univoco mostrato per la scelta del Ring.

Si salvano ID, nome, etichetta e scelta Modifica. Gli ID conservano
l'associazione anche dopo una rinomina del gruppo. Nessun gruppo e preselezionato: **Ring99 e escluso**. La prima volta scegliere
esplicitamente i gruppi dalle impostazioni; le installazioni esistenti non
ricevono gruppi assegnati automaticamente. Un nome configurato senza ID
viene risolto solo se univoco fino alla selezione per ID nelle impostazioni. I gruppi non selezionati non entrano
nel calcolo. Un gruppo mancante, duplicato per nome o non leggibile interrompe
la ricerca: non viene ignorato e non produce falsi orfani.

## Lettura e assegnazione

All’apertura parte automaticamente la lettura completa dei gruppi selezionati,
di tutte le loro appartenenze transitive e dei dispositivi Entra.
**Aggiorna dati / F5** ripete l’intera scansione anche se sono attivi filtri. I candidati sono Windows, ServerAd, Corporate,
gestiti MDM e abilitati. Le appartenenze sono confrontate con **Object ID
Entra**, non con Device ID. La vista iniziale **Tutti** mostra lo stato di ogni candidato, sia orfano
sia gia assegnato. **Filtra elenco** e i filtri di stato selezionano solo i
risultati gia caricati, senza nuove richieste ai servizi. E possibile isolare
orfani, gia assegnati, appartenenze multiple e anomalie GLPI. Il contatore
riporta visualizzati sul totale e selezionati. I contatori dei gruppi considerano gli oggetti transitivi letti.

Intune arricchisce l'inventario tramite Azure AD Device ID. GLPI usa seriale
Intune quando disponibile, poi il nome esatto se il seriale non trova schede.
Un risultato solo per nome viene segnalato da verificare se il seriale manca
o e diverso in GLPI; non conferma da solo l identita hardware. Mostra ID, nome effettivo,
stato, gruppo, CENSITO e inventario nei dettagli. Le ricerche raggruppate
considerano ogni seriale o nome come alternativa, indipendentemente
dall'ordine dei criteri. **Apri scheda GLPI** apre l'unica scheda associata
alla riga selezionata. Duplicati, conflitti seriali
e fonti non verificabili sono espliciti. Il modulo consulta GLPI: assegnare un
Ring aggiunge l'appartenenza Entra e non modifica la scheda GLPI.

Scegliere manualmente un Ring nelle righe dei PC, anche gia assegnati, oppure
impostarlo sulle righe selezionate. **Verifica modifiche** prepara una lista
con azione, PC, Object ID, destinazione e ogni origine da rimuovere, con nome
e ID del gruppo. **Applica modifiche** richiede conferma esplicita; Invio
rimane associato ad Annulla. I filtri locali non applicano alcuna modifica.

Il piano privato scade dopo cinque minuti ed e utilizzabile una sola volta.
Prima di applicarlo vengono rilette identita e caratteristiche dei gruppi,
requisiti del dispositivo e appartenenze dirette e transitive a tutti i gruppi
monitorati. Se sono cambiati occorre aggiornare i dati e ripetere l anteprima.

Lo spostamento aggiunge prima il PC alla destinazione e ne verifica
l appartenenza diretta. Solo allora rimuove le origini elencate e confermate,
una per volta, con successiva rilettura. Il backend usa esclusivamente
`DELETE /groups/{groupId}/members/{objectId}/$ref`: rimuove l appartenenza,
mai l oggetto dispositivo. Le origini devono essere configurate con Modifica
abilitata e ancora modificabili. Un appartenenza ereditata da un gruppo
annidato non puo essere rimossa dal solo PC e viene segnalata come bloccata.
I gruppi non configurati restano intatti. Se il PC e gia soltanto nel Ring di
destinazione l operazione non aggiunge ne rimuove appartenenze.

Se aggiunta o verifica destinazione falliscono, nessuna origine viene
rimossa. Se fallisce una rimozione, la destinazione verificata viene
conservata e il resoconto indica l esito parziale, fase e origini confermate.
Le riletture hanno un numero limitato di tentativi; non sono ripetuti
automaticamente POST o DELETE e non si tenta un rollback della destinazione.
Aggiornare i dati prima di riprovare. Graph non offre una transazione atomica:
rimane possibile una modifica concorrente tra l ultima verifica e la scrittura.

Il modulo richiede lettura Entra e gruppi. I permessi delegati minimi pertinenti
sono `Device.Read.All` e `GroupMember.Read.All`; per aggiungere o rimuovere appartenenze
`GroupMember.ReadWrite.All`, oltre a lettura dispositivi e diritti del tecnico
sul gruppo. Non occorre `Directory.AccessAsUser.All` per queste assegnazioni.
L'accesso iniziale mostra i consensi mancanti; non li richiede durante l'uso.
Un GET riuscito non prova il diritto di modificare ogni gruppo. Le fonti primarie
sono [aggiunta membri](https://learn.microsoft.com/en-us/graph/api/group-post-members?view=graph-rest-1.0)
, [rimozione membri](https://learn.microsoft.com/en-us/graph/api/group-delete-members?view=graph-rest-1.0)
e [membri transitivi](https://learn.microsoft.com/en-us/graph/api/group-list-transitivemembers?view=graph-rest-1.0).

La proprieta opzionale `isAssignableToRole` puo essere nulla per un gruppo
ordinario: solo il valore true identifica un gruppo assegnabile a ruoli e
lo esclude. Gli altri requisiti strutturali rimangono obbligatori.

I resoconti vanno in `Reports/Ring` nella cartella dati personale e restano
nella scheda Resoconto operazioni. Il CSV della vista include solo le righe
visibili e protegge le celle che potrebbero essere interpretate come formule.

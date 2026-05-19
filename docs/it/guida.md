# Source Server Manager — Guida utente

## Indice

1. [Requisiti](#requisiti)
2. [Installazione](#installazione)
3. [Primo avvio](#primo-avvio)
4. [Menu principale](#menu-principale)
5. [Creare un server](#creare-un-server)
6. [Gestire un server](#gestire-un-server)
7. [Avvio e arresto](#avvio-e-arresto)
8. [Mod — MetaMod:Source e SourceMod](#mod)
9. [Gestione admin SourceMod](#gestione-admin-sourcemod)
10. [Firewall](#firewall)
11. [Impostazioni server](#impostazioni-server)
12. [File di configurazione](#file-di-configurazione)
13. [Aggiungere una lingua](#aggiungere-una-lingua)
14. [Icone di stato](#icone-di-stato)
15. [Domande frequenti](#domande-frequenti)

---

## Requisiti

- Windows 10 o 11
- PowerShell 5.1 (preinstallato su tutti i sistemi Windows moderni)
- Connessione internet (per il download di SteamCMD e l'installazione del server)
- ~20 GB di spazio libero su disco per ogni server

Non è necessario installare software aggiuntivo manualmente. SteamCMD viene scaricato automaticamente al primo utilizzo.

---

## Installazione

Scarica o clona il repository in una qualsiasi cartella del computer, poi fai doppio click su `start.bat`, oppure esegui da PowerShell:

```
.\start.bat
```

Il tool è portabile — funziona da qualsiasi percorso. Le installazioni dei server si trovano nella cartella `servers/`, separata dal codice dell'applicazione in `app/`.

---

## Primo avvio

Al primo avvio viene chiesto di selezionare una lingua. La scelta viene salvata automaticamente in `config/default_config.json` e non verrà riproposta nei lanci successivi.

Per cambiare lingua in seguito: **Impostazioni → Cambia lingua** dal menu principale, oppure imposta `"Language": ""` nel file di configurazione per far riapparire la selezione al prossimo avvio.

---

## Menu principale

| Opzione | Quando è visibile |
|---------|------------------|
| Crea server | Sempre |
| Lista server completa | Solo quando i server superano il limite visualizzato nell'header |
| Gestisci server | Sempre |
| Riprendi installazione | In grigio quando nessun server ha un'installazione incompleta |
| Impostazioni | Sempre |
| Esci | Sempre |

L'header nella parte alta del menu principale mostra un riepilogo dei server registrati con il loro stato attuale. Vengono mostrati fino a 5 server per impostazione predefinita (configurabile tramite `HeaderServerLimit`).

---

## Creare un server

Dal menu principale, seleziona **Crea server**:

1. Inserisci un nome per il server (lettere, numeri e trattini — no spazi o caratteri speciali)
2. Inserisci un percorso di installazione, oppure lascia vuoto per usare il percorso predefinito dal file di configurazione

Il tool valida nome e percorso prima di procedere. Se la cartella di destinazione esiste già e non è vuota, viene mostrato un avviso — puoi continuare comunque (SteamCMD verificherà e sovrascriverà i file necessari) oppure annullare.

SteamCMD viene scaricato automaticamente al primo utilizzo, poi il server dedicato L4D2 viene installato nel percorso scelto. I tempi di installazione dipendono dalla velocità della connessione e sono tipicamente di 10–30 minuti.

### Installazione in background

L'installazione viene eseguita in una **finestra separata** — il programma principale torna subito al menu. Puoi continuare a usare il tool, creare altri server o avviare un'altra installazione mentre la prima è ancora in corso.

Il menu principale mostra `[>>]` in ciano accanto a ogni server che sta scaricando attivamente. Premi **R** nel menu del server per aggiornare lo stato in qualsiasi momento.

Puoi installare più server contemporaneamente — ognuno gira nella propria finestra indipendente.

---

## Gestire un server

Dal menu principale, seleziona **Gestisci server**, poi scegli un server dalla lista.

Prima di mostrare il menu delle azioni, viene visualizzata una scheda di stato con le informazioni aggiornate del server selezionato.

### Azioni disponibili

| Opzione | Descrizione |
|---------|-------------|
| Rinomina | Rinomina il server e la cartella su disco |
| Sposta | Sposta tutti i file del server in un nuovo percorso |
| Aggiorna | Riverifica e aggiorna i file tramite SteamCMD |
| Elimina | Rimuove il server dal registry (i file su disco non vengono eliminati) |
| Configura | Prima configurazione: scelta mappa e modalità di gioco |
| Cambia mappa/gamemode | Aggiorna mappa o modalità dopo la configurazione iniziale |
| Avvia / Arresta | Avvia o arresta il server |
| Riavvia | Riavvia il server (arresto poi avvio) |
| Firewall | Gestisce la regola Windows Firewall per questo server |
| Mod | Installa, verifica e gestisce MetaMod:Source e SourceMod |
| Gestisci admin | Gestisce la lista degli admin SourceMod |
| Impostazioni server | Imposta la password RCON e altre opzioni per questo server |
| Apri cartella | Apre la cartella del server in Esplora risorse |
| Indietro | Torna al menu principale |

Le opzioni non disponibili nello stato attuale vengono mostrate in grigio con il tag `[N/D]` e non possono essere selezionate. Ad esempio: Avvia, Configura, Mod e Admin sono tutte non disponibili finché l'installazione del server è incompleta o in errore — rimangono accessibili solo le operazioni di gestione (rinomina, sposta, elimina, aggiorna).

Premi **R) Aggiorna stato** in qualsiasi momento per aggiornare la visualizzazione senza uscire dal menu.

---

## Avvio e arresto

### Modalità di avvio

Al momento dell'avvio sono disponibili due modalità:

**Avvio normale**
Il server si apre nella propria finestra. In caso di crash, non si riavvia automaticamente.

**Auto-restart**
Un processo di monitoraggio separato sorveglia il server. Se crasha o si chiude inaspettatamente, viene riavviato automaticamente. Il monitor riprova fino a 100 volte con un'attesa di 5 secondi tra un tentativo e l'altro.

### Tracciamento dello stato

Lo stato del server è tracciato tramite un file `.running` all'interno della cartella del server. Questo file contiene l'ID del processo e l'orario di avvio. Il tool controlla questo file ogni volta che si accede al menu di gestione e rileva automaticamente se il server si è fermato.

### Arresto

Seleziona **Arresta server** dal menu di gestione. Il tool termina il processo del server (e il processo di monitoraggio, se era attiva la modalità auto-restart).

---

## Mod

Dal menu di gestione del server, seleziona **Mod**.

Il menu mod mostra lo stato di installazione corrente di MetaMod:Source e SourceMod, inclusi i numeri di versione quando sono installati.

### Installa versioni raccomandate

Recupera le ultime versioni stabili di MetaMod:Source e SourceMod dalle rispettive pagine di download e le installa direttamente nella cartella del server. Non è necessario scaricare o estrarre nulla manualmente.

Dopo l'installazione, se il server è in esecuzione, viene proposto il riavvio.

### Installa versione personalizzata

Mostra una lista di versioni disponibili per ciascuna mod (fino a 5 per mod), così è possibile selezionarne una specifica. Utile quando una particolare versione del gioco richiede una build più vecchia della mod.

### Verifica mod via RCON

Mentre il server è in esecuzione e l'RCON è configurato, questa opzione invia `meta version` e `sm version` alla console del server e mostra le risposte. Conferma che le mod siano effettivamente caricate, non solo presenti su disco.

> Le mod vengono caricate all'avvio del server. Se le hai appena installate, riavvia il server prima di verificare.

### Rimuovi mod

Rimuove MetaMod:Source e SourceMod dalla cartella del server. Richiede conferma prima di eliminare.

---

## Gestione admin SourceMod

Da **Mod → Gestisci admin**.

Questo menu gestisce il file `admins_simple.ini` che SourceMod legge all'avvio per determinare quali giocatori hanno permessi elevati.

### Aggiungere un admin

Tre metodi per aggiungere un admin:

| Metodo | Descrizione |
|--------|-------------|
| Dalla lista giocatori | Scegli tra i giocatori trovati nei log di SourceMod (richiede prima la scansione dei log) |
| Dai giocatori connessi | Scegli tra i giocatori attualmente connessi tramite RCON (il server deve essere in esecuzione) |
| Steam ID manuale | Inserisci direttamente uno Steam ID (formato: `STEAM_1:0:12345678`) |

Dopo aver selezionato un giocatore, scegli il livello di permesso:

| Livello | Flag | Accesso |
|---------|------|---------|
| Root | `z` | Accesso completo a tutti i comandi SourceMod |
| Moderatore | `bcd` | Kick, ban, cambio mappa |
| Personalizzato | definito dall'utente | Qualsiasi combinazione di flag di permesso SourceMod |

### Rimuovere un admin

Seleziona un admin dalla lista attuale per rimuoverlo. È richiesta conferma prima dell'eliminazione.

### Scansiona log

Analizza i file di log di SourceMod per costruire una lista dei giocatori che si sono connessi al server in passato. Questa lista viene salvata localmente e usata per popolare il selettore giocatori quando si aggiunge un admin.

### Applicare le modifiche

Le modifiche ad `admins_simple.ini` hanno effetto al prossimo avvio del server. Se il server è in esecuzione e l'RCON è configurato, il tool invia automaticamente `sm admins rebuild` per applicare le modifiche senza riavvio.

---

## Firewall

Dal menu di gestione del server, seleziona **Firewall**.

Questa opzione aggiunge o rimuove una regola in entrata di Windows Firewall che apre la porta 27015 (la porta di gioco predefinita di Source Engine).

> La gestione del firewall richiede privilegi di amministratore. In caso di errore di permesso, riavvia PowerShell come Amministratore.

La scheda di stato nel menu di gestione mostra se una regola firewall è attualmente presente per il server.

---

## Impostazioni server

Dal menu di gestione del server, seleziona **Impostazioni server**.

Impostazioni attualmente disponibili:

**Password RCON**
Imposta la password della console remota per il server. La password viene scritta in `server.cfg` e consente al tool di inviare comandi al server in esecuzione (verifica mod, ricarica admin, lista giocatori).

La scheda di stato mostra `[OK] ***` quando la password è impostata, oppure `[--] Non impostata` quando non lo è.

---

## File di configurazione

`config/default_config.json` controlla il comportamento globale del tool:

| Campo | Tipo | Descrizione |
|-------|------|-------------|
| `Language` | stringa | Codice lingua interfaccia (`en`, `it`). Imposta `""` per richiedere al prossimo avvio |
| `DefaultInstallRoot` | stringa | Percorso predefinito per le nuove installazioni server |
| `EnableLogging` | bool | Scrive i log di sessione in `logs/manager.log` |
| `DefaultMaxPlayers` | intero | Numero massimo di giocatori predefinito per nuovi server |
| `HeaderServerLimit` | intero | Numero di server mostrati nell'header del menu principale (default: 5) |

`config/servers_registry.json` contiene la lista dei server registrati. Questo file è escluso dal controllo versione perché contiene percorsi specifici della macchina.

---

## Aggiungere una lingua

1. Copia `locale/en.json` in `locale/{codice}.json` (es. `locale/de.json`)
2. Traduci tutti i valori delle stringhe — lascia invariate le chiavi JSON
3. Imposta il campo `LanguageName` con il nome nativo della lingua (es. `"Deutsch"`)
4. La lingua appare automaticamente in **Impostazioni → Cambia lingua** al prossimo avvio

---

## Icone di stato

### Lista server

| Icona | Colore | Significato |
|-------|--------|-------------|
| `[OK]` | Verde | Server installato e pronto |
| `[>>]` | Ciano | Download attivamente in corso (finestra SteamCMD aperta) |
| `[!!]` | Giallo | Installazione incompleta o errore (nessun download attivo) |
| `[--]` | Rosso | Percorso non trovato su disco |

### Scheda di stato (menu gestione)

| Campo | Stati |
|-------|-------|
| Installazione | Installato / In installazione / Mancante / Corrotto |
| Configurazione | Configurato / Non configurato |
| MetaMod / SourceMod | Attivo / Non caricato / Non installato |
| Firewall | Regola presente / Nessuna regola |
| Stato | In esecuzione / Non in esecuzione |
| RCON | Attivo (con conteggio giocatori) / Configurato / Non raggiungibile / Password non impostata |

---

## Domande frequenti

**Posso spostare la cartella del server manualmente?**
Sì. Successivamente usa **Gestisci → Sposta** per aggiornare il registry al nuovo percorso.

**Ho eliminato il server ma i file sono ancora su disco — è normale?**
Sì. Elimina rimuove solo la voce dal registry. I file su disco non vengono mai eliminati automaticamente. Rimuovili manualmente se necessario.

**L'opzione Firewall riporta un errore di permesso.**
Il tool deve essere eseguito come Amministratore per aggiungere o rimuovere regole Windows Firewall. Clicca con il tasto destro su PowerShell e seleziona "Esegui come amministratore".

**Ho installato le mod ma non sono attive.**
Le mod vengono caricate all'avvio del server. Riavvia il server dopo l'installazione. Usa **Mod → Verifica** per confermare che siano caricate.

**Come ripristino la selezione della lingua?**
Imposta `"Language": ""` in `config/default_config.json`, oppure usa **Impostazioni → Cambia lingua** dall'interno del tool.

**L'auto-restart continua a riavviare un server che crasha — come lo fermo?**
Usa **Gestisci → Arresta server** dal menu del tool. Termina sia il processo del server che il processo di monitoraggio.

**Il registry mostra un server come Mancante ma i file ci sono.**
Il percorso salvato nel registry non corrisponde alla posizione effettiva della cartella. Usa **Gestisci → Sposta** e inserisci il percorso corretto per ricollegarli.

**Posso installare più server contemporaneamente?**
Sì. Ogni installazione gira nella propria finestra separata in modo indipendente. Il programma principale rimane sempre reattivo.

**Ho chiuso la finestra di installazione per errore — cosa succede?**
Lo stato del server viene impostato automaticamente a Errore la prossima volta che apri il menu del server. Da lì, seleziona **Aggiorna** (opzione 9) per riavviare l'installazione.

**Il menu mostra `[!!]` giallo ma non sta scaricando niente.**
L'installazione è stata interrotta (finestra chiusa, crash o interruzione di corrente). Seleziona **Aggiorna** dal menu del server per riprendere.

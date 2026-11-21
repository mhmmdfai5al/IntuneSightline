# Setup guide

From nothing to a first report. About 15 minutes, once per tenant.

Do the parts in order. Each part ends with **Check** — don't move on until it matches.

| Part | Who does it | Done once per |
|---|---|---|
| [1. Install PowerShell 7](#1-install-powershell-7) | You | Computer |
| [2. Create the app registration](#2-create-the-app-registration) | An Entra admin | Tenant |
| [3. Add the permissions](#3-add-the-permissions) | An Entra admin | Tenant |
| [4. Grant admin consent](#4-grant-admin-consent) | An admin who can consent | Tenant |
| [5. Check your Intune role](#5-check-your-intune-role) | An Intune admin | Person |
| [6. Download and run](#6-download-and-run) | You | Computer |
| [7. Connect](#7-connect) | You | Computer |

If something goes wrong, go to [When it goes wrong](#when-it-goes-wrong) and find the error text.

---

## 1. Install PowerShell 7

The app needs **PowerShell 7**. The *Windows PowerShell 5.1* that comes with Windows is a
different program and will not work.

**Windows** — open *Terminal* or *Command Prompt* and run:

```
winget install --id Microsoft.PowerShell --source winget
```

**macOS** — download the `.pkg` for your Mac from the
[PowerShell releases page](https://aka.ms/powershell-release?tag=stable) (`osx-arm64` for
Apple silicon, `osx-x64` for Intel) and double-click it.

**Check:** open a new terminal and run `pwsh -v`. It prints `PowerShell 7.x.x`.

---

## 2. Create the app registration

Every tenant uses its own registration. That is where the app's permissions live; the
app has none of its own.

You need at least the **Application Developer** role in Entra.

1. Go to [entra.microsoft.com](https://entra.microsoft.com) and sign in.
2. If you can see more than one tenant, use the **Settings** (gear) icon at the top to
   switch to the right one.
3. Go to **Entra ID** > **App registrations** > **New registration**.
4. **Name:** `IntuneSightline` (any name works; people will see it on the consent screen).
5. **Supported account types:** **Single tenant only** (*Accounts in this organizational
   directory only* on older screens).
6. **Redirect URI:** leave it empty here. It is added in the next step.
7. Select **Register**.

Now add the redirect URI. **This is the step most often missed.**

8. In the registration, go to **Authentication**. Some tenants show it as
   **Authentication (Preview)** — same page.
9. Select **Add Redirect URI** (older screens: **Add a platform**).
10. Select the **Mobile and desktop applications** tile.
    **Not** *Web*, and **not** *Single-page application* — both break sign-in.
11. Under **Custom redirect URIs**, type exactly:
    ```
    http://localhost
    ```
    `http`, not `https`. No port, no slash at the end.
12. Select **Configure**.
13. Find **Allow public client flows** (on the **Settings** tab, or under
    **Advanced settings**) and set it to **Yes** / **Enabled**. Select **Save**.
    This only matters if browser sign-in fails and the app falls back to a code, but
    without it that fallback fails too.

**Check:**
- **Authentication** lists `http://localhost` under **Mobile and desktop applications**.
- **Allow public client flows** is **Yes**.
- On **Overview** you can see the **Application (client) ID** and **Directory (tenant) ID**.
  Keep this page open; you need both in part 7.

---

## 3. Add the permissions

1. In the registration, go to **API permissions**.
2. `User.Read` is already there. Leave it.
3. Select **Add a permission** > **Microsoft Graph** > **Delegated permissions**.
   *Delegated*, not *Application* — application permissions will not work.
4. Use the search box to find and tick each of these:

   | Type in search | Tick |
   |---|---|
   | `DeviceManagementManagedDevices` | `DeviceManagementManagedDevices.Read.All` |
   | `DeviceManagementConfiguration` | `DeviceManagementConfiguration.Read.All` |
   | `DeviceManagementServiceConfig` | `DeviceManagementServiceConfig.Read.All` |
   | `DeviceManagementApps` | `DeviceManagementApps.Read.All` |
   | `DeviceManagementScripts` | `DeviceManagementScripts.Read.All` |
   | `DeviceManagementRBAC` | `DeviceManagementRBAC.Read.All` |
   | `Group.Read` | `Group.Read.All` |
   | `Device.Read` | `Device.Read.All` |
   | `User.ReadBasic` | `User.ReadBasic.All` |

   Tick only the ones ending in **`.Read.All`** (`User.ReadBasic.All` for the last).
   Never tick a `ReadWrite` one — the app discards write permissions anyway, so they only
   add risk.

5. Select **Add permissions**.

`Directory.Read.All` can replace `Device.Read.All` if your tenant already uses it. You
don't need both.

**Check:** **API permissions** lists **10** Microsoft Graph permissions, all of type
**Delegated**: `User.Read` plus the nine above. Most show *Not granted* — that is fixed in
part 4.

---

## 4. Grant admin consent

You need one of: **Privileged Role Administrator**, **Cloud Application Administrator**
or **Application Administrator**. (Global Administrator also works.) If the button below
is greyed out, you don't have one of these — ask someone who does.

1. Still on **API permissions**, select **Grant admin consent for *your tenant name***.
2. Select **Yes**.
3. Select **Refresh**.

**Check:** every row's **Status** says **Granted for *your tenant name*** with a green tick.
None say *Not granted*.

> Adding or removing a permission later puts the status back to *Not granted*. Do this
> part again every time you change the list.

---

## 5. Check your Intune role

Graph permissions decide what the **app** may ask for. Your Intune role decides what
**you** may see. You need both.

Any of these is enough:
- the **Intune Administrator** role in Entra, or
- an Intune role with read access, such as the built-in **Read Only Operator**
  (Intune admin center > **Tenant administration** > **Roles**).

Reports only include what your role and its scope tags let you see. Under a scope tag,
"nothing found" can mean "nothing you are allowed to see".

**Check:** you can open **Devices** and **Apps** in the
[Intune admin center](https://intune.microsoft.com) and see items there.

---

## 6. Download and run

1. Download the latest zip from the project's
   [Releases](https://github.com/mhmmdfai5al/IntuneSightline/releases/latest) page —
   the asset named `IntuneSightline-v….zip`, **not** *Source code*.
2. Extract it somewhere you can find again, such as your Documents folder.
3. Open a terminal **in the extracted folder** (the one containing
   `Start-IntuneSightline.ps1`):
   - **Windows:** open the folder in File Explorer, right-click empty space,
     **Open in Terminal**. Then type `pwsh` and press Enter.
   - **macOS:** open *Terminal*, type `cd ` (with a space), drag the folder into the
     window, press Enter. Then type `pwsh` and press Enter.
4. **Windows only, first time only.** Windows blocks scripts from downloaded zips. Run:
   ```powershell
   Get-ChildItem -Recurse | Unblock-File
   ```
5. Start the app:
   ```powershell
   ./Start-IntuneSightline.ps1
   ```

**Check:** the terminal prints a preflight list with no **FAIL** lines, then a browser
page opens at `http://127.0.0.1:8787`. **Leave the terminal open** — closing it stops the
app.

---

## 7. Connect

1. On the page, fill in:
   - **Tenant ID** — the **Directory (tenant) ID** from the registration's Overview page
     (or your `something.onmicrosoft.com` domain).
   - **Application (client) ID** — the **Application (client) ID** from the same page.

   Copy them; don't type them. Both are 36 characters with four dashes.
2. Select **Connect** and sign in with the account from part 5.
3. If a **Permissions requested** screen appears, consent in part 4 was not completed.
   If you're an admin you can tick **Consent on behalf of your organisation** and select
   **Accept**; otherwise go back to part 4.

**Check:**
- The page shows **Connected** and your account at the top.
- The tool list shows every tool with no grey ones.
- If a tool says **Leaves out …**, that run will skip something; the line names the
  permission that adds it back (part 3, then part 4 again).
- Hover **Read access** at the top of the page to see the permissions this session has.

The tenant and application IDs are remembered for next time. Reports are saved in
`Documents\IntuneSightline` on Windows and `~/IntuneSightline` on macOS.

---

## When it goes wrong

Find the error text, then follow the fix.

| You see | Cause | Fix |
|---|---|---|
| `pwsh` is not recognised / command not found | PowerShell 7 not installed, or terminal opened before installing | Part 1, then open a **new** terminal |
| `#Requires … Version 7.0` / script won't start in *Windows PowerShell* | Running in PowerShell 5.1 | Type `pwsh` first, then run the script |
| `… is not digitally signed` / `cannot be loaded` (Windows) | Files still marked as downloaded | Part 6 step 4 |
| `AADSTS500113: No reply address is registered` | No redirect URI | Part 2 steps 8–12 |
| `AADSTS50011: The redirect URI … does not match` | Redirect URI typed differently, e.g. `https`, a path, or a typo | Part 2 step 11: exactly `http://localhost` |
| `AADSTS7000218: … must contain … client_secret` | Redirect URI added under **Web**, not **Mobile and desktop** | Delete the Web one; redo part 2 steps 9–12 |
| `AADSTS700016: Application … was not found in the directory` | Wrong Application ID, or registration is in a different tenant | Copy both IDs again from the registration's **Overview** |
| `AADSTS90002: Tenant … not found` | Wrong Tenant ID | Copy the **Directory (tenant) ID** again |
| **Need admin approval** / `AADSTS90094` / `AADSTS65001` | Admin consent not granted (or a permission was added since) | Part 4 |
| **Permissions requested** screen | Same as above, but you're an admin who can consent | Tick *Consent on behalf of your organisation*, **Accept** — or part 4 |
| Grey tool: **Needs X — not consented** | Permission X missing or not consented | Add X (part 3), grant consent (part 4), then **Disconnect** and **Connect** again |
| **Leaves out …** on a tool card | Optional permission missing; the tool still runs | Same as above if you want it; otherwise ignore |
| Report coverage shows `incomplete : 403 (Forbidden).` | Permission granted, but your **Intune role** can't read that area | Part 5 |
| Browser page doesn't open | Browser launch blocked | Open `http://127.0.0.1:8787` yourself |
| Port 8787 already in use | Another program on that port | `./Start-IntuneSightline.ps1 -Port 8788` and open that port instead |

A change in Entra reaches the app only on a new sign-in. After any change in parts 2–5,
select **Disconnect**, then **Connect**.

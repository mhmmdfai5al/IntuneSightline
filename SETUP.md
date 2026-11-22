# Setup

Do this once per tenant, in the Microsoft Entra admin center.

**You need** an Entra account with one of these roles: Global Administrator, Privileged
Role Administrator, Cloud Application Administrator or Application Administrator. Any of
them can both create the registration and grant the consent in step 4.

## 1. Create the registration

At [entra.microsoft.com](https://entra.microsoft.com), go to **Entra ID** › **App registrations** › **New registration**.

- **Name:** anything, for example `IntuneSightline`
- **Supported account types:** Single tenant only (on older screens, *Accounts in this organizational directory only*)
- **Redirect URI:** leave empty; step 2 adds it

Select **Register**.

## 2. Add the redirect URI

In the new registration, open **Authentication**.

- Select **Add Redirect URI** (on older screens, **Add a platform**), then **Mobile and desktop applications**.
- Under custom redirect URIs, enter `http://localhost` and select **Configure**.
- Turn on **Allow public client flows** and select **Save**. It is on the **Settings** tab, or under **Advanced settings** on older screens.

> [!IMPORTANT]
> Choose **Mobile and desktop applications**. A *Web* or *Single-page application* redirect URI makes sign-in fail.

## 3. Add the permissions

Open **API permissions** › **Add a permission** › **Microsoft Graph** › **Delegated permissions**.

Add each permission in the [README's table](README.md#prerequisites). Leave `User.Read`, which is already there.

## 4. Grant consent

Still on **API permissions**, select **Grant admin consent for *your tenant***, then **Yes**.

Every permission should now show **Granted for *your tenant***.

## 5. Copy two IDs

Open **Overview** and copy:

- **Directory (tenant) ID**
- **Application (client) ID**

Enter these in the app when you select **Connect**.

> [!TIP]
> Added a permission later? Repeat step 4, then **Disconnect** and **Connect** in the app.

## If something goes wrong

| What you see | What to do |
|---|---|
| **AADSTS500113** – no reply address | Do step 2 |
| **AADSTS50011** – redirect URI doesn't match | In step 2, enter exactly `http://localhost` |
| **AADSTS7000218** – client secret required | The redirect URI is under *Web*. Delete that entry and redo step 2 |
| **AADSTS9002327** – single-page application | The redirect URI is under *Single-page application*. Delete that entry and redo step 2 |
| **AADSTS700016** – application not found | Copy both IDs again (step 5) |
| **AADSTS90002** – tenant not found | Copy the tenant ID again (step 5) |
| *Need admin approval* or *Permissions requested* | Do step 4 |
| A tool is greyed out | Add the permission it names (step 3), then step 4 |
| `403 (Forbidden)` in a report | If the tool's card says **Leaves out**, add that permission. Otherwise your Intune role can't read that area; ask for a read role such as Read Only Operator |
| *pwsh* not recognised or not found | Install PowerShell 7, then open a new terminal |
| *… is not digitally signed* (Windows) | Run the unblock line from the README Quick start, step 4 |
| Startup fails because port 8787 is in use | Start with `./Start-IntuneSightline.ps1 -Port 8788` |

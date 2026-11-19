# Accounts and Sign-In

## Sign in with your browser

Choose your Audible marketplace. If you use separate accounts, give this one a name you will recognise in the account menu.

Click **Continue**, then **Open Sign-In Page**. Complete the Amazon sign-in in your browser, including any verification it asks for. Copy the full address of the final page from your browser’s address bar. Paste it into DownAudible and click **Sign In**. Even if the final page itself is blank, DownAudible needs the full address.

The legacy Audible username option is available for the UK, US, and German marketplaces. Use it if your sign-in predates Amazon accounts.

## Import from Audible CLI

Open **Settings > Accounts > Import from Audible CLI**. Choose **CLI profile** to read profiles from the CLI’s configuration file. DownAudible looks for `config.toml` in the CLI’s configured directory, usually `~/.audible`. Click **Choose** if your configuration is stored elsewhere.

Choose **Auth file** to open an authentication file directly. Enter its Audible CLI password if it is encrypted. You can give the account a different display name and pick the marketplace if the file needs one. DownAudible saves the imported session in your Mac’s Keychain.

## Switch or remove an account

Use the account menu in the Library toolbar, or select an account in **Settings > Accounts** and click **Switch to This Account**. The library and file matches change with the account. A running batch uses the account it started with.

**Sign Out** clears the saved session, so you can sign in to that profile again later. **Remove Account** also removes the profile and its file matches. Use **Rename** to change the name shown in the account menu.

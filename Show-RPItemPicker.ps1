function Show-RPItemPicker {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]$Title = "Select Item(s)",
        [Parameter()]
        [string[]]$Kind,
        [Parameter()]
        [switch]$ConfigItemsCamsOnly
    )

    #import-module C:\RemotePro\RemotePro\RemotePro.psd1
    Add-Type -AssemblyName PresentationFramework

    # Define the XAML with the button included
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Milestone Item Picker" Height="600" Width="800">
    <Grid x:Name="mainGrid" Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>
        <ContentControl x:Name="itemPickerHost" Grid.Row="0" Margin="5" />
        <Button Content="Get Selected Items" Grid.Row="1" HorizontalAlignment="Center" VerticalAlignment="Center"
                Margin="10" Padding="10,5" Background="#007ACC" Foreground="White" BorderBrush="#005A9E" BorderThickness="1" />
    </Grid>
</Window>
"@

    # Convert the XAML string to XML
    $reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)

    # Load the XAML
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    # Create an instance of the ItemPickerWpfUserControl
    $itemPickerControl = New-Object VideoOS.Platform.UI.ItemPickerWpfUserControl

    # Set properties to customize the behavior of the control
    $itemPickerControl.AllowGroupSelection = $true
    $itemPickerControl.AutoExpand = $true
    $itemPickerControl.EmptyListOverlayText = "No items selected"
    $itemPickerControl.IsMultiSelection = $true
    $itemPickerControl.SearchEnabled = $true
    $itemPickerControl.SearchPlaceholderText = "Search for items..."
    $itemPickerControl.TableHeader = "Selected Items"

    # Initialize the items list
    $itemsList = New-Object 'System.Collections.Generic.List[VideoOS.Platform.Item]'

    function Get-KindGuid {
        param ($kindName)
        switch ($kindName) {
            "Camera" { return [VideoOS.Platform.Kind]::Camera }
            "Hardware" { return [VideoOS.Platform.Kind]::Hardware }
            "Server" { return [VideoOS.Platform.Kind]::Server }
            default { throw "Unknown kind: $kindName" }
        }
    }

    # Retrieve items from the server based on Kind
    if ($Kind -and $Kind.Count -gt 0) {
        foreach ($kindName in $Kind) {
            $kindGuid = Get-KindGuid -kindName $kindName
            $items = Get-VmsVideoOSItem -Kind $kindGuid -ItemHierarchy 'SystemDefined' -FolderType 'SystemDefined'
            if ($items) {
                foreach ($item in $items) {
                    if ($item -is [VideoOS.Platform.Item]) {
                        $itemsList.Add($item)
                    }
                }
            }
        }
    } else {
        $items = Get-VmsVideoOSItem -ItemHierarchy 'SystemDefined' -FolderType 'SystemDefined' -Verbose
        foreach ($item in $items) {
            if ($item -is [VideoOS.Platform.Item]) {
                $itemsList.Add($item)
            }
        }
    }

    if ($itemsList.Count -gt 0) {
        # Set the Items property directly
        $itemPickerControl.Items = $itemsList
    } else {
        Write-Verbose "No items retrieved from the server"
    }

    $script:selectedItemDetails = @()

    try {
        # Event handler for the button click
        $button = $window.FindName("mainGrid").Children | Where-Object { $_ -is [System.Windows.Controls.Button] }
        $button.Add_Click({
            $script:selectedItemDetails = $itemPickerControl.SelectedItems | ForEach-Object {
                @{
                    Name = $_.Name
                    Id = $_.FQID.ObjectId
                    FQID = $_.FQID
                }
            }
            Write-Verbose "Number of selected items: $($script:selectedItemDetails.Count)"
            foreach ($item in $script:selectedItemDetails) {
                Write-Verbose "Selected item: Name=$($item.Name), Id=$($item.Id), FQID=$($item.FQID)"
            }
            $window.DialogResult = $true
            $window.Close()
        })

        # Add the ItemPickerWpfUserControl to the ContentControl
        $itemPickerHost = $window.FindName("itemPickerHost")
        $itemPickerHost.Content = $itemPickerControl

        # Show the WPF window
        $window.ShowDialog() | Out-Null

        # Filter the original items based on the selected item IDs
        $script:selectedItems = $itemPickerControl.SelectedItems | Where-Object { $script:selectedItemDetails.Id -contains $_.FQID.ObjectId }

        # Debug output to check what is being returned
        Write-Verbose "Returning items: $($script:selectedItems.Count)"
        foreach ($item in $script:selectedItems) {
            Write-Verbose "Returning item: Name=$($item.Name), Id=$($item.FQID.ObjectId), FQID=$($item.FQID)"
        }

        # Switch and logic for return items of type VideoOS.Platform.ConfigurationItems.Camera
        if ($ConfigItemsCamsOnly){
            # Final type = VideoOS.Platform.ConfigurationItems.Camera
            $cameras = [System.Collections.Generic.List[VideoOS.Platform.ConfigurationItems.Camera]]::new()


            foreach ($item in $script:selectedItems){
                switch ($item.GetType().FullName) { #Switches ensures selected object types get handled correctly.
                    #region Camera Items
                    "VideoOS.Platform.SDK.Platform.CameraItem" {
                        # Convert Camera objects from type Platform to Configruation
                        $camera = Get-VmsCamera -Id $item.FQID.ObjectId
                        $cameras.Add($camera)
                    }
                    #endregion

                    #region Hardware Items
                    "VideoOS.Platform.SDK.Platform.HardwareItem" {
                        # Convert Hardware objects from type Platform to Configuration
                        $configItemCam = Get-VmsHardware -id $item.FQID.ObjectId.ToString() | Get-VmsCamera
                        $cameras.Add($configItemCam)
                    }
                    #endregion

                    #region All Hardware folders
                    "VideoOS.Platform.SDK.Platform.HardwareFolderItem" {
                        # VideoOS.Platform.SDK.Platform.HardwareFolderItem
                        $hwFolder = $item.GetChildren()

                        # VideoOS.Platform.ConfigurationItems.Hardware
                        $hwItems = $hwFolder.Values | Get-VmsHardware

                        # Final Conversion: Completed type to VideoOS.Platform.SDK.Platform.CameraItem
                        foreach ($hw in $hwItems) {
                            $configItemCam = $hw | Get-VmsCamera
                            $cameras.Add($configItemCam)
                        }
                    }
                    #endregion

                    #region All Camera folders
                    "VideoOS.Platform.SDK.Platform.AllRSFolderItem" {
                        # VideoOS.Platform.SDK.Platform.AllRSFolderItem
                        $camFolder = $item.GetChildren()

                        # Final Conversion: Completed type to VideoOS.Platform.SDK.Platform.CameraItem
                        foreach ($cam in $camFolder) {
                            $camera = Get-VmsCamera -Id $cam.FQID.ObjectId
                            $cameras.Add($camera)
                        }
                    }
                    #endregion

                    #region Recording Server Folders
                    "VideoOS.Platform.SDK.Platform.ServerFolderByTypeItem" {
                        # Unnroll recording servers
                        $srvFolderChildren = $item.GetChildren()


                        Write-Host "Doink!"
                        # (plural) VideoOS.Platform.SDK.Platform.RecorderFolderByTypeItem to VideoOS.Platform.ConfigurationItems.RecordingServer
                        $recServers = $srvFolderChildren | Get-RecordingServer


                        # Final Conversion: Completed type to VideoOS.Platform.SDK.Platform.CameraItem
                        foreach ($server in $recServers) {
                            $server | Get-VmsHardware | Get-VmsCamera | ForEach-Object { $cameras.Add($_) }
                        }
                    }
                    #endregion

                    #region Recording Servers
                    "VideoOS.Platform.SDK.Platform.ServerFolderByTypeItem" {
                        # (single) VideoOS.Platform.SDK.Platform.RecorderFolderByTypeItem to VideoOS.Platform.ConfigurationItems.RecordingServer
                        $recServer = $item | Get-RecordingServer

                        # Final Conversion: Completed type to VideoOS.Platform.SDK.Platform.CameraItem
                        $recServer | Get-VmsHardware | Get-VmsCamera | ForEach-Object { $cameras.Add($_) }
                    }
                    #endregion
                }
            }

            return $cameras #VideoOS.Platform.SDK.Platform.CameraItem
        } else {
            return $script:selectedItems # VideoOS.Platform.SDK.Platform type objects
        }
    }
    catch {
        Write-Error "An error occurred: $_"
    }
    finally {
        # Properly dispose of the window and control
        if ($null -ne $itemPickerControl) {
            $itemPickerControl.Dispose()
        }
        if ($null -ne $window) {
            $window.Close()
        }
    }
}

Function AppManager()
    if m.AppManager = invalid then
        obj = CreateObject("roAssociativeArray")

        'obj.productCode = "PROD1" ' Sample product when sideloaded
        obj.productCode = "plexunlock"

        ' The unlocked state of the app, one of: Plex Pass, Exempt, Purchased, Trial, or Limited
        obj.IsPlexPass = (RegRead("IsPlexPass", "misc", "0") = "1")
        obj.IsEntitled = (RegRead("IsEntitled", "misc", "0") = "1")
        obj.IsPurchased = (RegRead("purchased", "misc", "0") = "1")
        obj.IsAvailableForPurchase = false
        obj.IsExempt = false

        obj.firstPlaybackTimestamp = RegRead("first_playback_timestamp", "misc")
        if obj.firstPlaybackTimestamp <> invalid then
            currentTime = Now().AsSeconds()
            firstPlayback = obj.firstPlaybackTimestamp.toint()
            trialDuration = 30 * 24 * 60 * 60 ' 30 days
            obj.IsInTrialWindow = (currentTime - firstPlayback < trialDuration)
        else
            ' The user hasn't tried to play any media yet, still in trial.
            obj.IsInTrialWindow = true
        end if

        obj.ResetState = managerResetState
        obj.ResetState()

        ' Track anything that needs to be initialized before the app can start
        ' and an initial screen can be shown. These need to be important,
        ' generally related to whether the app is unlocked or not.
        obj.Initializers = CreateObject("roAssociativeArray")
        obj.AddInitializer = managerAddInitializer
        obj.ClearInitializer = managerClearInitializer
        obj.IsInitialized = managerIsInitialized

        ' Media playback is allowed if the app is unlocked or still in a trial
        ' period. So, basically, if it's not Limited.
        obj.IsPlaybackAllowed = managerIsPlaybackAllowed

        ' Channel store
        obj.FetchProducts = managerFetchProducts
        obj.HandleChannelStoreEvent = managerHandleChannelStoreEvent
        obj.StartPurchase = managerStartPurchase
        obj.CheckStoreTimeout = managerCheckStoreTimeout
        obj.StoreTimeout = 10

        ' Singleton
        m.AppManager = obj

        obj.FetchProducts()
    end if

    return m.AppManager
End Function

Sub managerAddInitializer(name)
    m.Initializers[name] = true
End Sub

Sub managerClearInitializer(name)
    if m.Initializers.Delete(name) AND m.IsInitialized() then
        GetViewController().OnInitialized()
    end if
End Sub

Function managerIsInitialized() As Boolean
    m.Initializers.Reset()
    status = m.Initializers.IsEmpty()
    m.CheckStoreTimeout()
    return status
End Function

Function managerIsPlaybackAllowed() As Boolean
    ' If we've never noted a playback attempt before, write it to the registry
    ' now. It will serve as the start of the trial period.

    if m.firstPlaybackTimestamp = invalid then
        RegWrite("first_playback_timestamp", tostr(Now().AsSeconds()), "misc")
    end if

    return m.State <> "Limited"
End Function

Sub managerResetState()
    if m.IsPlexPass then
        m.State = "Plex Pass"
    else if m.IsEntitled then
        m.State = "Entitlement"
    else if m.IsExempt then
        m.State = "Exempt"
    else if m.IsPurchased then
        m.State = "Purchased"
    else if m.IsInTrialWindow then
        m.State = "Trial"
    else
        m.State = "Limited"
    end if

    if m.State <> "Limited" and m.State <> "Trial" then
        m.StateDisplay = "Unlocked"
    else
        m.StateDisplay = m.State
    end if

    Debug("App state is now: " + m.StateDisplay + " (" + m.State + ")")
End Sub

Sub managerCheckStoreTimeout()
    if m.StoreTimer <> invalid and m.StoreTimer.GetElapsedSeconds() > m.StoreTimeout then
        Debug("Channel Store timed out: " + tostr(m.StoreTimer.GetElapsedSeconds()))
        m.StoreTimer = invalid
        m.ResetState()
        m.ClearInitializer("channelstore")
   end if
end Sub

Sub managerFetchProducts()
    ' On the older firmware, the roChannelStore exists, it just doesn't seem to
    ' work. So don't even bother, just say that the item isn't available for
    ' purchase on the older firmware.

    if CheckMinimumVersion(GetGlobal("rokuVersionArr", [0]), [5, 1]) then
        m.AddInitializer("channelstore")

        ' The docs suggest we can make two requests at the same time by using the
        ' source identity, but it doesn't actually work. So we have to get the
        ' catalog and purchases serially. Start with the purchases, so that if
        ' we get a response we can skip the catalog request.

        store = CreateObject("roChannelStore")
        store.SetMessagePort(GetViewController().GlobalMessagePort)
        store.GetPurchases()
        m.PendingStore = store
        m.PendingRequestPurchased = true
        m.StoreTimer = createTimer()
    else
        ' Rather than force these users to have a Plex Pass, we'll exempt them.
        ' Among other things, this allows old users to continue to work, since
        ' even though they've theoretically been grandfathered we don't know it.
        m.IsExempt = true
        Debug("Channel store isn't supported by firmware version")
        m.ResetState()
    end if
End Sub

Sub managerHandleChannelStoreEvent(msg)
    m.StoreTimer = invalid
    m.PendingStore = invalid
    atLeastOneProduct = false

    if msg.isRequestSucceeded() then
        if m.PendingRequestPurchased then m.IsPurchased = false
        for each product in msg.GetResponse()
            atLeastOneProduct = true
            if product.code = m.productCode then
                m.IsAvailableForPurchase = true
                if m.PendingRequestPurchased then
                    m.IsPurchased = true
                    RegWrite("purchased", "1", "misc")
                end if
            end if
        next
    end if

    ' If the cataglog had at least one product, but not ours, then the user is
    ' exempt. This essentially allows sideloaded channels to be exempt without
    ' having to muck with anything.

    if NOT m.PendingRequestPurchased AND NOT m.IsAvailableForPurchase AND atLeastOneProduct then
        Debug("Channel is exempt from trial period")
        m.IsExempt = true
    end if

    ' If this was a purchases request and we didn't find anything, then issue
    ' a catalog request now.
    if m.PendingRequestPurchased AND NOT m.IsPurchased then
        Debug("Channel does not appear to be purchased, checking catalog")
        store = CreateObject("roChannelStore")
        store.SetMessagePort(GetViewController().GlobalMessagePort)
        store.GetCatalog()
        m.PendingStore = store
        m.PendingRequestPurchased = false
    else
        Debug("IAP is available: " + tostr(m.IsAvailableForPurchase))
        Debug("IAP is purchased: " + tostr(m.IsPurchased))
        Debug("IAP is exempt: " + tostr(m.IsExempt))
        m.ResetState()
    end if

    if m.PendingStore = invalid then
        m.ClearInitializer("channelstore")
    end if
End Sub

Sub managerStartPurchase()
    store = CreateObject("roChannelStore")
    cart = CreateObject("roList")
    order = {code: m.productCode, qty: 1}
    cart.AddTail(order)
    store.SetOrder(cart)

    if store.DoOrder() then
        Debug("Product purchased!")
        RegWrite("purchased", "1", "misc")
        m.IsPurchased = true
        m.ResetState()
    else
        Debug("Product not purchased")
    end if
End Sub

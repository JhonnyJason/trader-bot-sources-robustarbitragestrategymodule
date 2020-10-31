headstrategymodule = {name: "headstrategymodule"}
############################################################
#region printLogFunctions
log = (arg) ->
    if allModules.debugmodule.modulesToDebug["headstrategymodule"]?  then console.log "[headstrategymodule]: " + arg
    return
ostr = (obj) -> JSON.stringify(obj, null, 4)
olog = (obj) -> log "\n" + ostr(obj)
print = (arg) -> console.log(arg)
#endregion

############################################################
#region modules
situationAnalyzer = null
state = null
cfg = null
utl = null

#endregion

############################################################
#region internalProperties
params = null
#region paramsExample
# params =
#     headVolumePercent: 5
#     baseDistancePercent: 0.1
#     inbalancePressure: 15
#     profitRatioMeToExchange: 1.5
#     headRecreationDelayM: 5
#     heartbeatM: 0.5
#endregion
situations = null

currentIdeas = {}
currentHeads = {}

relevantIdeas = {}
relevantIdeasReady = false
#endregion

############################################################
headstrategymodule.initialize = () ->
    log "headstrategymodule.initialize"
    situationAnalyzer = allModules.situationanalyzermodule
    state = allModules.persistentstatemodule
    utl = allModules.utilmodule


    cfg = allModules.configmodule
    situations = situationAnalyzer.situations
    params = cfg.headStrategy

    currentIdeas = state.load("headStrategyIdeas")

    ## synchronize State with config
    exchanges = cfg.activeExchanges
    
    #add the stuff which is missing
    for exchange in exchanges
        currentHeads[exchange] = {} unless currentHeads[exchange]?
        currentIdeas[exchange] = {} unless currentIdeas[exchange]?
        for assetPair in cfg[exchange].assetPairs
            if !currentHeads[exchange][assetPair]?
                currentHeads[exchange][assetPair] =
                    buyHead: null
                    sellHead: null
            currentIdeas[exchange][assetPair] = [] unless currentIdeas[exchange][assetPair]?

    for exchange,assetPairMap of currentIdeas
        if !exchanges.includes(exchange) then delete currentIdeas[exchange]
        else for assetPair,ideaList of assetPairMap
            if !cfg[exchange].assetPairs.includes(assetPair) then delete currentIdeas[exchange][assetPair]
            else for idea in ideaList
                if idea.isBuyHead then currentHeads[exchange][assetPair].buyHead = idea
                if idea.isSellHead then currentHeads[exchange][assetPair].sellHead = idea

    state.save("headStrategyIdeas", currentIdeas)
    return

############################################################
#region internalFunctions
heartbeat = ->
    log " > heartbeat"
    return unless situationAnalyzer.ready

    for exchange,assetPairMap of currentIdeas
        for assetPair,ideaList of assetPairMap
            evolveIdeas(exchange, assetPair)
            createRelevantIdeas(exchange, assetPair)
    
    # log "currentIdeas:"
    # olog currentIdeas
    # log "currentHeads:"
    # olog currentHeads

    state.save("headStrategyIdeas", currentIdeas)
    return

############################################################
createRelevantIdeas = (exchange,assetPair) ->
    allIdeas = currentIdeas[exchange][assetPair]
    close = getLatestClosingPrice(exchange, assetPair)
    topRelevanceFactor = getTopRelevanceFactor(exchange, assetPair) 
    bottomRelevanceFactor = getBottomRelevanceFactor(exchange, assetPair) 
    topPriceLimit = close * topRelevanceFactor
    bottomPriceLimit = close * bottomRelevanceFactor
    relevantIdeas[exchange] = {} unless relevantIdeas[exchange]?
    relevantIdeas[exchange][assetPair] = []
    for idea in allIdeas 
        if idea.price < topPriceLimit and idea.price > bottomPriceLimit
            delete idea.isCancelled
            relevantIdeas[exchange][assetPair].push idea
        else delete idea.id
    relevantIdeasReady = true
    return

evolveIdeas = (exchange, assetPair) ->
    # log "evolveIdeas"
    handleRealizedIdeas(exchange, assetPair)
    resetUselessHeads(exchange, assetPair)
    createMissingHeads(exchange, assetPair)
    return

############################################################
#region evolutionProcesses
handleRealizedIdeas = (exchange, assetPair) ->
    heads = currentHeads[exchange][assetPair]

    if heads.buyHead and heads.buyHead.eaten
        addSellBackIdea(exchange, assetPair, heads.buyHead)
        heads.buyHead = null

    if heads.sellHead and heads.sellHead.eaten
        addBuyBackIdea(exchange, assetPair, heads.sellHead)
        heads.sellHead = null

    return

resetUselessHeads = (exchange, assetPair) ->
    heads = currentHeads[exchange][assetPair]

    if heads.buyHead and buyHeadNeedsReset(exchange, assetPair)
        resetBuyHead(exchange, assetPair)

    if heads.sellHead and sellHeadNeedsReset(exchange, assetPair)
        resetSellHead(exchange, assetPair)
    return    

createMissingHeads = (exchange, assetPair) ->
    heads = currentHeads[exchange][assetPair]

    if !heads.buyHead? then setNewBuyHead(exchange, assetPair)
    if !heads.sellHead? then setNewSellHead(exchange, assetPair)
    return

############################################################
addBuyBackIdea = (exchange, assetPair, sellOrder) ->
    ideaList = currentIdeas[exchange][assetPair]
    heads = currentHeads[exchange][assetPair]    
    newOrder = createBuyBackOrder(sellOrder)
    return unless newOrder

    if heads.buyHead and newOrder.price > heads.buyHead.price
        oldHead = heads.buyHead
        newOrder.isBuyHead = true            
        heads.buyHead = newOrder

        delete oldHead.isBuyHead
        removeIdea(oldHead) unless oldHead.isBuyBack

    currentIdeas[exchange][assetPair].push(newOrder)
    return

addSellBackIdea = (exchange, assetPair, buyOrder) ->
    ideaList = currentIdeas[exchange][assetPair]
    heads = currentHeads[exchange][assetPair]
    newOrder = createSellBackOrder(buyOrder)
    return unless newOrder

    if heads.sellHead and newOrder.price < heads.sellHead.price
        oldHead = heads.sellHead
        newOrder.isSellHead = true
        heads.sellHead = newOrder

        delete oldHead.isSellHead
        removeIdea(oldHead) unless oldHead.isSellBack
        
    currentIdeas[exchange][assetPair].push(newOrder)
    return

############################################################
sellHeadNeedsReset = (exchange, assetPair) ->
    # log "sellHeadNeedsReset?"
    heads = currentHeads[exchange][assetPair]
    if heads.buyHead then return false
        
    thoughtHeadPrice = calculateSellHeadPrice(exchange, assetPair)
    # log "thoughtHeadPrice: " + thoughtHeadPrice
    sellHeadPrice = heads.sellHead.price
    # log "current sellHeadPrice: " + sellHeadPrice

    noResetRangePercent = 2 * params.baseDistancePercent
    # log "noResetRangePercent: "+noResetRangePercent
    noResetRangeFactor = noResetRangePercent * 0.01
    # log "noResetRangeFactor: "+noResetRangeFactor
    noResetRange = sellHeadPrice * noResetRangeFactor
    # log "noResetRange: "+noResetRange

    resetPrice = sellHeadPrice - noResetRange 
    
    if thoughtHeadPrice < resetPrice then return true 

    return false

buyHeadNeedsReset = (exchange, assetPair) ->
    # log "buyHeadNeedsReset?"
    heads = currentHeads[exchange][assetPair]
    if heads.sellHead then return false
        
    thoughtHeadPrice = calculateBuyHeadPrice(exchange, assetPair)
    # log "thoughtHeadPrice: " + thoughtHeadPrice
    buyHeadPrice = heads.buyHead.price
    # log "current sellHeadPrice: " + sellHeadPrice

    noResetRangePercent = 2 * params.baseDistancePercent
    # log "noResetRangePercent: "+noResetRangePercent
    noResetRangeFactor = noResetRangePercent * 0.01
    # log "noResetRangeFactor: "+noResetRangeFactor
    noResetRange = buyHeadPrice * noResetRangeFactor
    # log "noResetRange: "+noResetRange

    resetPrice = buyHeadPrice + noResetRange 
    
    if thoughtHeadPrice > resetPrice  then return true 

    return false

resetBuyHead = (exchange, assetPair) ->
    # log "resetBuyHead"
    heads = currentHeads[exchange][assetPair]
    idea = heads.buyHead
    delete idea.isBuyHead
    heads.buyHead = null
    setNewBuyHead(exchange, assetPair)
    removeIdea(idea) unless idea.isBuyBack
    return

resetSellHead = (exchange, assetPair) ->
    # log "resetSellHead"
    heads = currentHeads[exchange][assetPair]
    idea = heads.sellHead
    delete idea.isSellHead
    heads.sellHead = null
    setNewSellHead(exchange, assetPair)
    removeIdea(idea) unless idea.isSellBack
    return

############################################################
setNewBuyHead = (exchange, assetPair) ->
    heads = currentHeads[exchange][assetPair]
    if heads.buyHead then return
    ## first we check if we can just use the current topmost buy as the next buyHead
    # df is some difference factor for a tolerance range
    # we just take the baseDistance as tolerance distance for which we still count the existing buy as valid new head
    # this is because we donot want to have too many close orders at the same place
    df = (100 + params.baseDistancePercent) * 0.01 
    topBuy = getTopBuyOrder(exchange, assetPair)

    newBuyPrice = calculateBuyHeadPrice(exchange, assetPair)
    if topBuy and (topBuy.price*df) >= newBuyPrice
        # log "taking over topBuy as buyHead"
        topBuy.isBuyHead = true
        heads.buyHead = topBuy
        return
   
    ## Okay we do need a newBuyHead
    newBuyHead = createNewBuyHead(exchange, assetPair)
    return unless newBuyHead
    
    ## if we have a sellback waiting on the other side already we donot want to create another head
    sellBackPrice = calculateSellBackPrice(exchange, assetPair, newBuyHead.price)
    return unless sellBackSpaceIsAvailable(exchange, assetPair, sellBackPrice)

    currentIdeas[exchange][assetPair].push newBuyHead
    heads.buyHead = newBuyHead
    return

setNewSellHead = (exchange, assetPair) ->
    heads = currentHeads[exchange][assetPair]
    if heads.sellHead then return
    ## first we check if we may just use the curren bottommost sell as next sellHead
    # df is some difference factor for a tolerance range
    # we just take the baseDistance as the tolerance distance for which we still count the existing buy as valid new sellHead
    # this is because we donot want to have too many close orders at the same place
    df = (100 - params.baseDistancePercent) * 0.01
    bottomSell = getBottomSellOrder(exchange, assetPair)

    newSellPrice = calculateSellHeadPrice(exchange, assetPair)
    if bottomSell and (bottomSell.price*df) <= newSellPrice
        # log "taking over bottomSell as sellHead"
        bottomSell.isSellHead = true
        heads.sellHead = bottomSell
        return

    ## Okay we do need a newSellHead
    newSellHead = createNewSellHead(exchange, assetPair)
    return unless newSellHead

    ## if we have a buyback waiting on the other side already, we donot want to create another head
    buyBackPrice = calculateBuyBackPrice(exchange, assetPair, newSellHead.price)
    return unless buyBackSpaceIsAvailable(exchange, assetPair, buyBackPrice)
    
    currentIdeas[exchange][assetPair].push newSellHead
    heads.sellHead = newSellHead
    return

removeIdea = (ideaToRemove) ->
    exchange = ideaToRemove.exchange
    assetPair = ideaToRemove.assetPair
    for idea,index in currentIdeas[exchange][assetPair]
        if Object.is(idea, ideaToRemove)
            currentIdeas[exchange][assetPair].splice(index,1)
            return
    return

############################################################
sellBackSpaceIsAvailable = (exchange, assetPair, price) ->
    # log "sellBackSpaceIsAvailable?"
    topFactor = (100+params.baseDistancePercent) * 0.01
    topPrice = price * topFactor
    bottomFactor = (100-params.baseDistancePercent) * 0.01
    bottomPrice = price * bottomFactor
    ideaList = currentIdeas[exchange][assetPair]
    for idea in ideaList when idea.isSellBack
        if idea.price < topPrice and idea.price > bottomPrice then return false
    return true

buyBackSpaceIsAvailable = (exchange, assetPair, price) ->
    # log "buyBackSpaceIsAvailable?"
    topFactor = (100+params.baseDistancePercent) * 0.01
    topPrice = price * topFactor
    bottomFactor = (100-params.baseDistancePercent) * 0.01
    bottomPrice = price * bottomFactor
    ideaList = currentIdeas[exchange][assetPair]
    for idea in ideaList when idea.isBuyBack
        if idea.price < topPrice and idea.price > bottomPrice then return false
    return true

############################################################
getTopBuyOrder = (exchange, assetPair) ->
    # log "getTopBuyOrder"
    ideas = currentIdeas[exchange][assetPair]
    top = null
    for idea in ideas when idea.type == "buy"
        top = idea unless top
        if idea.price > top.price then top = idea
    return top

getBottomSellOrder = (exchange, assetPair) ->
    # log "getBottomSellOrder"
    ideas = currentIdeas[exchange][assetPair]
    bottom = null
    for idea in ideas when idea.type == "sell"
        bottom = idea unless bottom
        if idea.price < bottom.price then bottom = idea
    return bottom

#endregion

############################################################
#region ideaCreationHelpers

############################################################
#region createOrders
createNewBuyHead = (exchange, assetPair) ->
    order = {}
    order.isBuyHead = true
    order.owner = headstrategymodule.name
    order.exchange = exchange
    order.assetPair = assetPair
    order.type = "buy"
    order.price = calculateBuyHeadPrice(exchange, assetPair)
    order.volume = calculateBuyHeadVolume(exchange, assetPair, order.price)
    # log " -> buyHead created!"
    # olog order
    minVolume = params.specific[exchange][assetPair].minVolume
    if order.volume < minVolume then return null
    return order

createNewSellHead = (exchange, assetPair) ->
    order = {}
    order.isSellHead = true
    order.owner = headstrategymodule.name
    order.exchange = exchange
    order.assetPair = assetPair
    order.type = "sell"
    order.price = calculateSellHeadPrice(exchange, assetPair)
    order.volume = calculateSellHeadVolume(exchange, assetPair)
    # log " -> sellHead created!"
    # olog order
    minVolume = params.specific[exchange][assetPair].minVolume
    if order.volume < minVolume then return null
    return order

createBuyBackOrder = (sellOrder) ->
    exchange = sellOrder.exchange
    assetPair = sellOrder.assetPair
    sellPrice = sellOrder.price
    sellVolume = sellOrder.volume

    order = {}
    order.isBuyBack = true
    order.owner = headstrategymodule.name
    order.exchange = exchange
    order.assetPair = assetPair
    order.type = "buy"
    order.price = calculateBuyBackPrice(exchange, assetPair, sellPrice)
    order.volume = sellVolume
    # log "created buyBack:"
    # olog order
    minVolume = params.specific[exchange][assetPair].minVolume
    if order.volume < minVolume then return null
    return order

createSellBackOrder = (buyOrder) ->
    exchange = buyOrder.exchange
    assetPair = buyOrder.assetPair
    buyPrice = buyOrder.price
    buyVolume = buyOrder.volume

    order = {}
    order.isSellBack = true
    order.owner = headstrategymodule.name
    order.exchange = exchange
    order.assetPair = assetPair
    order.type = "sell"
    order.price = calculateSellBackPrice(exchange, assetPair, buyPrice)
    order.volume = buyVolume
    # log "created sellBack:"
    # olog order

    minVolume = getMinVolume(exchange, assetPair)    
    if order.volume < minVolume then return null
    return order

#endregion

############################################################
getMinDif = (precision) ->
    zero = 0.0
    minDif = zero.toFixed(precision-1) + 1
    return parseFloat(minDif)

getVolumePrecision = (exchange, assetPair) ->
    return params.volumePrecision unless params.specific[exchange]?
    return params.volumePrecision unless params.specific[exchange][assetPair]?
    return params.volumePrecision unless params.specific[exchange][assetPair].volumePrecision?
    return params.specific[exchange][assetPair].volumePrecision    

getPricePrecision = (exchange, assetPair) ->
    return params.pricePrecision unless params.specific[exchange]?
    return params.pricePrecision unless params.specific[exchange][assetPair]?
    return params.pricePrecision unless params.specific[exchange][assetPair].pricePrecision?
    return params.specific[exchange][assetPair].pricePrecision

getMinVolume = (exchange, assetPair) ->
    return params.minVolume unless params.specific[exchange]?
    return params.minVolume unless params.specific[exchange][assetPair]?
    return params.minVolume unless params.specific[exchange][assetPair].minVolume?
    return params.specific[exchange][assetPair].minVolume

getHeadVolumePercent = (exchange, assetPair) ->
    return params.headVolumePercent unless params.specific[exchange]?
    return params.headVolumePercent unless params.specific[exchange][assetPair]?
    return params.headVolumePercent unless params.specific[exchange][assetPair].headVolumePercent?
    return params.specific[exchange][assetPair].headVolumePercent

getRelevanceScopePercent = (exchange, assetPair) ->
    return params.relevanceScopePercent unless params.specific[exchange]?
    return params.relevanceScopePercent unless params.specific[exchange][assetPair]?
    return params.relevanceScopePercent unless params.specific[exchange][assetPair].relevanceScopePercent?
    return params.specific[exchange][assetPair].relevanceScopePercent
    return

############################################################
#region calculatePrices
calculateBuyBackPrice = (exchange, assetPair, sellPrice) ->
    precision = getPricePrecision(exchange, assetPair)
    factor = getBuyPriceFactor(exchange)
    exact = sellPrice * factor * factor 
    price = parseFloat(exact.toFixed(precision)) 
    return price

calculateSellBackPrice = (exchange, assetPair, buyPrice) ->
    precision = getPricePrecision(exchange, assetPair)
    minDif = getMinDif(precision)
    factor = getSellPriceFactor(exchange)
    exact = buyPrice * factor * factor + minDif
    price = parseFloat(exact.toFixed(precision))
    return price

calculateBuyHeadPrice = (exchange, assetPair) ->
    precision = getPricePrecision(exchange, assetPair)
    factor = getBuyHeadPriceFactor(exchange, assetPair)
    latestBid = getLatestBidPrice(exchange, assetPair)
    latestClose = getLatestClosingPrice(exchange, assetPair)
    if latestBid > latestClose then exact = latestClose * factor
    else exact = latestBid * factor
    price = parseFloat(exact.toFixed(precision))
    return price

calculateSellHeadPrice = (exchange, assetPair) ->
    precision = getPricePrecision(exchange, assetPair)
    minDif = getMinDif(precision)
    factor = getSellHeadPriceFactor(exchange, assetPair)
    latestAsk = getLatestAskPrice(exchange, assetPair)
    latestClose = getLatestClosingPrice(exchange, assetPair)
    if latestAsk < latestClose then exact = latestClose * factor +  minDif
    else exact = latestAsk * factor +  minDif
    price = parseFloat(exact.toFixed(precision)) 
    return price

#endregion

############################################################
#region calculateVolumes
calculateBuyHeadVolume = (exchange, assetPair, price) ->
    precision = getVolumePrecision(exchange, assetPair)
    headVolumePercent = getHeadVolumePercent(exchange, assetPair)
    factor = headVolumePercent * 0.01 / price
    assets = assetPair.split("-")
    assetSituation = situations[exchange].assets[assets[1]]
    # log "assetSituation: "+exchange+"/"+assetPair
    # olog assetSituation
    available = assetSituation.totalVolume - assetSituation.lockedVolume
    availableVolume = available / price
    # log "available: " + available
    minVolume = getMinVolume(exchange, assetPair)
    return 0.0 unless availableVolume > minVolume * 2

    exactVolume = factor * available
    volume = parseFloat(exactVolume.toFixed(precision))
    return minVolume unless volume > minVolume

    return volume

calculateSellHeadVolume = (exchange, assetPair) ->
    precision = getVolumePrecision(exchange, assetPair)
    headVolumePercent = getHeadVolumePercent(exchange, assetPair)
    factor = headVolumePercent * 0.01
    assets = assetPair.split("-")
    assetSituation = situations[exchange].assets[assets[0]]
    # log "assetSituation: "+exchange+"/"+assetPair
    # olog assetSituation
    available = assetSituation.totalVolume - assetSituation.lockedVolume
    # log "available: " + available
    minVolume = getMinVolume(exchange, assetPair)
    return 0.0 unless available > minVolume * 2

    exact = factor * available
    volume = parseFloat(exact.toFixed(precision))
    return minVolume unless volume > minVolume
    
    return volume

#endregion

############################################################
#region priceHelperFunctions
getBuyHeadPriceFactor = (exchange, assetPair) ->
    # log "getBuyHeadPriceFactor"
    baseDistance = params.baseDistancePercent
    pressure = params.inbalancePressure
    inbalance = (1.0 / getBalanceRatio(exchange, assetPair)) - 1
    # log "inbalance: " + inbalance
    if inbalance > 0 then inbalance = 0
    # inbalance = Math.abs(inbalance)
    inbalance = Math.pow(inbalance, 20)
    # log "inbalance: " + inbalance
    # log "added term: " + (baseDistance*pressure*inbalance)
    distance = baseDistance*(1 + pressure*inbalance)
    factor = (100 - distance) * 0.01
    # log "factor: " + factor
    return factor

getSellHeadPriceFactor = (exchange, assetPair) ->
    # log "getSellHeadPriceFactor"
    baseDistance = params.baseDistancePercent
    pressure = params.inbalancePressure
    inbalance = getBalanceRatio(exchange, assetPair) - 1
    # log "inbalance: " + inbalance
    if inbalance > 0 then inbalance = 0
    # inbalance = Math.abs(inbalance)
    inbalance = Math.pow(inbalance, 20)
    # log "inbalance:  " + inbalance
    # log "added term: " + (baseDistance*pressure*inbalance)
    distance = baseDistance*(1 + pressure*inbalance)
    factor = (100 + distance ) * 0.01
    # log "factor: " + factor
    return factor

getBuyPriceFactor = (exchange) ->
    feePercent = cfg[exchange].makerFeePercent
    marginPercent = feePercent*(1+params.profitRatioMeToExchange)
    pricePercent = 100 - marginPercent
    return 0.01 * pricePercent

getSellPriceFactor = (exchange) ->
    feePercent = cfg[exchange].makerFeePercent
    marginPercent = feePercent*(1+params.profitRatioMeToExchange)
    pricePercent = 100 + marginPercent
    return 0.01 * pricePercent

getTopRelevanceFactor = (exchange, assetPair) ->
    totalScopePercent = getRelevanceScopePercent(exchange, assetPair)
    topScopePercent = 0.5 * totalScopePercent
    factor = (100 + topScopePercent) * 0.01
    return factor

getBottomRelevanceFactor = (exchange, assetPair) ->
    totalScopePercent = getRelevanceScopePercent(exchange, assetPair)
    bottomScopePercent = 0.5 * totalScopePercent
    factor = (100 - bottomScopePercent) * 0.01    
    return factor

getLatestClosingPrice = (exchange, assetPair) ->
    assets = assetPair.split("-")
    exchangeSituation = situations[exchange]
    assetSituation = exchangeSituation.assets[assets[0]]
    prices = assetSituation.pricesTo[assets[1]]
    return prices.closingPrice

getLatestBidPrice = (exchange, assetPair) ->
    assets = assetPair.split("-")
    exchangeSituation = situations[exchange]
    assetSituation = exchangeSituation.assets[assets[0]]
    prices = assetSituation.pricesTo[assets[1]]
    return prices.bidPrice

getLatestAskPrice = (exchange, assetPair) ->
    assets = assetPair.split("-")
    exchangeSituation = situations[exchange]
    assetSituation = exchangeSituation.assets[assets[0]]
    prices = assetSituation.pricesTo[assets[1]]
    return prices.askPrice

getBalanceRatio = (exchange, assetPair) ->
    # log "getBalanceRatio"
    # log "for assetPair " + assetPair 
    assets = assetPair.split("-")
    exchangeSituation = situations[exchange]
    assetSituation = exchangeSituation.assets[assets[0]]
    volume0 = assetSituation.totalVolume
    volume0 *= assetSituation.pricesTo[assets[1]].closingPrice
    # log "volume0: " + volume0
    assetSituation = exchangeSituation.assets[assets[1]]
    volume1 = assetSituation.totalVolume
    # log "volume1: " + volume1
    return (volume0 / volume1)

#endregion

#endregion

#endregion

############################################################
#region exposedFunctions
headstrategymodule.start = ->
    log "headstrategymodule.start"
    heartbeatMS = params.heartbeatM * 60 * 1000
    heartBeatTimerId = setInterval(heartbeat, heartbeatMS)
    return

############################################################
headstrategymodule.getCurrentIdeas = -> currentIdeas
headstrategymodule.getRelevantIdeas = ->
    return null unless relevantIdeasReady
    return relevantIdeas

############################################################
headstrategymodule.noticeRelevantEvents = (events) ->
    # log "headstrategymodule.noticeRelevantEvents"

    # Events could be: 
    ## --
    ## instaFill
    ## instaCancel
    ## --
    ## filled
    ## cancelled
    ## --
    ## stupidIdeaNoticed
    ## --

    for event in events
        # olog event
        if event.type == "filled" or event.type == "instaFill"
            exchange = event.idea.exchange
            assetPair = event.idea.assetPair
            return unless currentIdeas[exchange]?
            return unless currentIdeas[exchange][assetPair]?
            
            removeIdea(event.idea)
            ## check if it was an insta-filled head
            heads = currentHeads[exchange][assetPair]
            
            if heads.sellHead and Object.is(heads.sellHead, event.idea)
                heads.sellHead.eaten = true
            if heads.buyHead and Object.is(heads.buyHead, event.idea)
                heads.buyHead.eaten = true

        if event.type == "cancelled" or event.type == "instaCancel"
            exchange = event.idea.exchange
            assetPair = event.idea.assetPair
            return unless currentIdeas[exchange]?
            return unless currentIdeas[exchange][assetPair]?

            delete event.idea.isRealized
            delete event.idea.id

            removeIdea(event.idea) unless event.idea.isBuyBack or event.idea.isSellBack

            heads = currentHeads[exchange][assetPair]
            if heads.sellHead and Object.is(heads.sellHead, event.idea)
                heads.sellHead = null 
            if heads.buyHead and Object.is(heads.buyHead, event.idea)
                heads.buyHead = null

        if event.type == "stupidIdeaNoticed"
            exchange = event.idea.exchange
            assetPair = event.idea.assetPair
            return unless currentIdeas[exchange]?
            return unless currentIdeas[exchange][assetPair]?

            removeIdea(event.idea) unless event.idea.isBuyBack or event.idea.isSellBack

            if event.idea.isSellBack
                sellHeadPrice = calculateSellHeadPrice()
                if sellHeadPrice > event.idea.price then event.idea.price = sellHeadPrice            

            if event.idea.isBuyBack
                buyHeadPrice = calculateBuyHeadPrice()
                if buyHeadPrice < event.idea.price then event.idea.price = buyHeadPrice

            ## also need to remove the heads if it was the heads
            heads = currentHeads[exchange][assetPair]
            if heads.sellHead and Object.is(heads.sellHead, event.idea)
                heads.sellHead = null
            if heads.buyHead and Object.is(heads.buyHead, event.idea)
                heads.buyHead = null
    
    return

#endregion

module.exports = headstrategymodule
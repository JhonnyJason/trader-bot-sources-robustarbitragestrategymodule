robustarbitragestrategymodule = {name: "robustarbitragestrategymodule"}
############################################################
#region printLogFunctions
log = (arg) ->
    if allModules.debugmodule.modulesToDebug["robustarbitragestrategymodule"]?  then console.log "[robustarbitragestrategymodule]: " + arg
    return
ostr = (obj) -> JSON.stringify(obj, null, 4)
olog = (obj) -> log "\n" + ostr(obj)
print = (arg) -> console.log(arg)
#endregion

############################################################
#region modules
situationAnalyzer = null
budgetManager = null
state = null
cfg = null
utl = null

#endregion

############################################################
#region internalProperties
params = null
#region paramsExample
# params =
    # headVolumePercent: 0.75
    # baseDistancePercent: 0.4
    # baseBuyBackDistancePercent: 3
    # magnifier: 2
    # volumePrecision:2
    # pricePrecision: 2
    # heartbeatM: 0.5
#endregion
situations = null

currentIdeas = {}
currentHeads = {}
currentBackOrders = {}

currentIterations = {}
isCancelling = false
#endregion

############################################################
robustarbitragestrategymodule.initialize = ->
    log "robustarbitragestrategymodule.initialize"
    situationAnalyzer = allModules.situationanalyzermodule
    budgetManager = allModules.budgetmanagermodule
    state = allModules.persistentstatemodule
    utl = allModules.utilmodule

    cfg = allModules.configmodule
    situations = situationAnalyzer.situations
    params = cfg.robustArbitrageStrategyParams

    currentIdeas = state.load("robustArbitrageStrategyIdeas")
    ## synchronize State with config
    exchanges = cfg.activeExchanges
    
    #add the stuff which is missing
    for exchange in exchanges
        currentIdeas[exchange] = {} unless currentIdeas[exchange]?
        currentHeads[exchange] = {} unless currentHeads[exchange]?
        currentBackOrders[exchange] = {} unless currentBackOrders[exchange]?
        currentIterations[exchange] = {} unless currentIterations[exchange]?
        for assetPair in cfg[exchange].assetPairs
            if !currentHeads[exchange][assetPair]?
                currentHeads[exchange][assetPair] =
                    buyHead: null
                    sellHead: null
            if !currentBackOrders[exchange][assetPair]?
                currentBackOrders[exchange][assetPair] = 
                    buyBack: null
                    sellBack: null
            if !currentIterations[exchange][assetPair]?
                currentIterations[exchange][assetPair] = 
                    buy: 0
                    sell: 0
            currentIdeas[exchange][assetPair] = [] unless currentIdeas[exchange][assetPair]?


    for exchange,assetPairMap of currentIdeas
        if !exchanges.includes(exchange) then delete currentIdeas[exchange]
        else for assetPair,ideaList of assetPairMap
            if !cfg[exchange].assetPairs.includes(assetPair) then delete currentIdeas[exchange][assetPair]
            else 
                for idea in ideaList when idea?
                    if idea.isBuyHead 
                        currentHeads[exchange][assetPair].buyHead = idea
                        currentIterations[exchange][assetPair].buy = idea.iteration
                    if idea.isSellHead 
                        currentHeads[exchange][assetPair].sellHead = idea
                        currentIterations[exchange][assetPair].sell = idea.iteration
                    if idea.isBuyBack then currentBackOrders[exchange][assetPair].buyBack = idea
                    if idea.isSellBack then currentBackOrders[exchange][assetPair].sellBack = idea
                reflectToCurrentIdeas(exchange, assetPair)

    state.save("robustArbitrageStrategyIdeas", currentIdeas)
    return
    
############################################################
#region internalFunctions
heartbeat = ->
    log " > heartbeat"
    return unless situationAnalyzer.ready

    for exchange,assetPairMap of currentIdeas
        for assetPair,ideaList of assetPairMap
            evolveIdeas(exchange, assetPair)
            reflectToCurrentIdeas(exchange, assetPair)
    # log "currentIdeas:"
    # olog currentIdeas
    # log "currentHeads:"
    # olog currentHeads

    state.save("robustArbitrageStrategyIdeas", currentIdeas)
    return

############################################################
reflectToCurrentIdeas = (exchange, assetPair) ->
    heads = currentHeads[exchange][assetPair]
    backOrders = currentBackOrders[exchange][assetPair]
    ideas = []
    if heads.sellHead then ideas.push(heads.sellHead)
    if heads.buyHead then ideas.push(heads.buyHead)
    if backOrders.sellBack then ideas.push(backOrders.sellBack)
    if backOrders.buyBack then ideas.push(backOrders.buyBack)
    currentIdeas[exchange][assetPair] = ideas
    return

evolveIdeas = (exchange, assetPair) ->
    # log "evolveIdeas"
    return if isCancelling
    await handleRealizedIdeas(exchange, assetPair)
    await resetUselessHeads(exchange, assetPair)
    createMissingHeads(exchange, assetPair)
    return

############################################################
#region evolutionProcesses
handleRealizedIdeas = (exchange, assetPair) ->
    heads = currentHeads[exchange][assetPair]
    backOrders = currentBackOrders[exchange][assetPair]
    iterations = currentIterations[exchange][assetPair]

    if heads.buyHead and heads.buyHead.eaten
        if backOrders.sellBack?
            await cancelIdea(backOrders.sellBack)
            freeAllocatedSellBudget(backOrders.sellBack)

        registerEatenBuyHead(heads.buyHead)

        setSellBackIdea(exchange, assetPair)
        iterations.buy++
        heads.buyHead = null

    if heads.sellHead and heads.sellHead.eaten
        if backOrders.buyBack?
            await cancelIdea(backOrders.buyBack)
            freeAllocatedBuyBudget(backOrders.buyBack)

        registerEatenSellHead(heads.sellHead)

        setBuyBackIdea(exchange, assetPair)
        iterations.sell++
        heads.sellHead = null
    
    if backOrders.buyBack and backOrders.buyBack.eaten
        if heads.sellHead?
            await cancelIdea(heads.sellHead)
            freeAllocatedSellBudget(heads.sellHead)

        registerEatenBuyBack(backOrders.buyBack)
        iterations.sell = 0
        heads.sellHead = null
        backOrders.buyBack = null

    if backOrders.sellBack and backOrders.sellBack.eaten
        if heads.buyHead?
            await cancelIdea(heads.buyHead)
            freeAllocatedBuyBudget(heads.buyHead)
        registerEatenSellBack(backOrders.sellBack)
        iterations.buy = 0
        heads.buyHead = null
        backOrders.sellBack = null

    return

resetUselessHeads = (exchange, assetPair) ->
    heads = currentHeads[exchange][assetPair]

    if heads.buyHead and buyHeadNeedsReset(exchange, assetPair)
        await resetBuyHead(exchange, assetPair)

    if heads.sellHead and sellHeadNeedsReset(exchange, assetPair)
        await resetSellHead(exchange, assetPair)
    return    

createMissingHeads = (exchange, assetPair) ->
    heads = currentHeads[exchange][assetPair]

    if !heads.buyHead? then setNewBuyHead(exchange, assetPair)
    # if !heads.sellHead? then setNewSellHead(exchange, assetPair)
    return

############################################################
setBuyBackIdea = (exchange, assetPair) ->
    newBuyBack = createBuyBackOrder(exchange, assetPair)
    try allocateBuyBudget(newBuyBack)
    catch err then log err.stack
    currentBackOrders[exchange][assetPair].buyBack = newBuyBack
    return

setSellBackIdea = (exchange, assetPair) ->
    newSellBack = createSellBackOrder(exchange, assetPair)
    try allocateSellBudget(newSellBack)
    catch err then log err.stack
    currentBackOrders[exchange][assetPair].sellBack = newSellBack
    return

############################################################
sellHeadNeedsReset = (exchange, assetPair) ->
    # log "sellHeadNeedsReset?"
    sellHead = currentHeads[exchange][assetPair].sellHead
    if sellHead.iteration > 0 then return false

    thoughtHeadPrice = calculateSellHeadPrice(exchange, assetPair)
    # log "thoughtHeadPrice: " + thoughtHeadPrice
    sellHeadPrice = sellHead.price
    # log "current sellHeadPrice: " + sellHeadPrice

    noResetRangePercent = 3 * params.baseDistancePercent
    # log "noResetRangePercent: "+noResetRangePercent
    noResetRangeFactor = noResetRangePercent * 0.01
    # log "noResetRangeFactor: "+noResetRangeFactor
    noResetRange = sellHeadPrice * noResetRangeFactor
    # log "noResetRange: "+noResetRange

    resetPrice = sellHeadPrice - noResetRange 
    
    if !sellHead.resetPressure? then sellHead.resetPressure = 0
    if thoughtHeadPrice < resetPrice then sellHead.resetPressure++
    else sellHead.resetPressure = 0

    if sellHead.resetPressure > 7 then return true
    return false

buyHeadNeedsReset = (exchange, assetPair) ->
    # log "buyHeadNeedsReset?"
    buyHead = currentHeads[exchange][assetPair].buyHead
    if buyHead.iteration > 0 then return false
        
    thoughtHeadPrice = calculateBuyHeadPrice(exchange, assetPair)
    # log "thoughtHeadPrice: " + thoughtHeadPrice
    buyHeadPrice = buyHead.price
    # log "current sellHeadPrice: " + sellHeadPrice

    noResetRangePercent = 3 * params.baseDistancePercent
    # log "noResetRangePercent: "+noResetRangePercent
    noResetRangeFactor = noResetRangePercent * 0.01
    # log "noResetRangeFactor: "+noResetRangeFactor
    noResetRange = buyHeadPrice * noResetRangeFactor
    # log "noResetRange: "+noResetRange

    resetPrice = buyHeadPrice + noResetRange 
    
    if !buyHead.resetPressure? then buyHead.resetPressure = 0
    if thoughtHeadPrice > resetPrice  then buyHead.resetPressure++
    else buyHead.resetPressure = 0
    
    if buyHead.resetPressure > 7 then return true 
    return false

resetBuyHead = (exchange, assetPair) ->
    log "resetBuyHead"
    idea = currentHeads[exchange][assetPair].buyHead
    
    await cancelIdea(idea)
    freeAllocatedBuyBudget(idea)
    
    currentHeads[exchange][assetPair].buyHead = null
    setNewBuyHead(exchange, assetPair)
    return

resetSellHead = (exchange, assetPair) ->
    log "resetSellHead"
    idea = currentHeads[exchange][assetPair].sellHead

    await cancelIdea(idea)
    freeAllocatedSellBudget(idea)

    currentHeads[exchange][assetPair].sellHead = null
    setNewSellHead(exchange, assetPair)
    return

############################################################
setNewBuyHead = (exchange, assetPair) ->
    heads = currentHeads[exchange][assetPair]
    if heads.buyHead then return

    newBuyHead = createNewBuyHead(exchange, assetPair)
    try allocateBuyBudget(newBuyHead)
    catch err
        log err.stack
        return

    heads.buyHead = newBuyHead
    return

setNewSellHead = (exchange, assetPair) ->
    heads = currentHeads[exchange][assetPair]
    if heads.sellHead then return
    
    newSellHead = createNewSellHead(exchange, assetPair)
    try allocateSellBudget(newSellHead)
    catch err
        log err.stack
        return

    heads.sellHead = newSellHead
    return

#endregion

############################################################
#region ideaCreationFunctions

############################################################
#region createOrders
createNewBuyHead = (exchange, assetPair) ->
    iteration = currentIterations[exchange][assetPair].buy
    order = {}
    order.isBuyHead = true
    order.iteration = iteration
    order.owner = robustarbitragestrategymodule.name
    order.exchange = exchange
    order.assetPair = assetPair
    order.type = "buy"
    order.price = calculateBuyHeadPrice(exchange, assetPair)
    order.volume = calculateBuyHeadVolume(exchange, assetPair)
    # log " -> buyHead created!"
    # olog order
    return order

createNewSellHead = (exchange, assetPair) ->
    iteration = currentIterations[exchange][assetPair].sell
    order = {}
    order.isSellHead = true
    order.iteration = iteration
    order.owner = robustarbitragestrategymodule.name
    order.exchange = exchange
    order.assetPair = assetPair
    order.type = "sell"
    order.price = calculateSellHeadPrice(exchange, assetPair)
    order.volume = calculateSellHeadVolume(exchange, assetPair)
    # log " -> sellHead created!"
    # olog order
    return order

createBuyBackOrder = (exchange, assetPair) ->
    order = {}
    order.isBuyBack = true
    order.owner = robustarbitragestrategymodule.name
    order.exchange = exchange
    order.assetPair = assetPair
    order.type = "buy"
    order.price = calculateBuyBackPrice(exchange, assetPair)
    order.volume = calculateBuyBackVolume(exchange, assetPair)
    # log "created buyBack:"
    # olog order
    return order

createSellBackOrder = (exchange, assetPair) ->
    order = {}
    order.isSellBack = true
    order.owner = robustarbitragestrategymodule.name
    order.exchange = exchange
    order.assetPair = assetPair
    order.type = "sell"
    order.price = calculateSellBackPrice(exchange, assetPair)
    order.volume = calculateSellBackVolume(exchange, assetPair)
    # log "created sellBack:"
    # olog order
    return order

#endregion

############################################################
#region parametersHelpers
tradableBuyPrice = (exchange, assetPair, price) ->
    precision = getPricePrecision(exchange, assetPair)
    return parseFloat(price.toFixed(precision))

tradableSellPrice = (exchange, assetPair, price) ->
    precision = getPricePrecision(exchange, assetPair)
    minDif = getMinDif(precision)
    price += minDif
    return parseFloat(price.toFixed(precision))

tradableBuyVolume = (exchange, assetPair, volume) ->
    precision = getVolumePrecision(exchange, assetPair)
    return parseFloat(volume.toFixed(precision))    

tradableSellVolume = (exchange, assetPair, volume) ->
    precision = getVolumePrecision(exchange, assetPair)
    minDif = getMinDif(precision)
    volume += minDif
    return parseFloat(volume.toFixed(precision))    

getMinDif = (precision) ->
    return 0 if precision == 0
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

getBaseDistancePercent = (exchange, assetPair) ->
    return params.baseDistancePercent unless params.specific[exchange]?
    return params.baseDistancePercent unless params.specific[exchange][assetPair]?
    return params.baseDistancePercent unless params.specific[exchange][assetPair].baseDistancePercent?
    return params.specific[exchange][assetPair].baseDistancePercent

getMagnifier = (exchange, assetPair) ->
    return params.magnifier unless params.specific[exchange]?
    return params.magnifier unless params.specific[exchange][assetPair]?
    return params.magnifier unless params.specific[exchange][assetPair].magnifier?
    return params.specific[exchange][assetPair].magnifier

getBackOrderDistancePercent = (exchange, assetPair) ->
    return params.backOrderDistancePercent unless params.specific[exchange]?
    return params.backOrderDistancePercent unless params.specific[exchange][assetPair]?
    return params.backOrderDistancePercent unless params.specific[exchange][assetPair].backOrderDistancePercent?
    return params.specific[exchange][assetPair].backOrderDistancePercent

#endregion

############################################################
#region calculatePrices
calculateBuyBackPrice = (exchange, assetPair) ->
    factor = getBuyBackPriceFactor(exchange, assetPair)

    sellHead = currentHeads[exchange][assetPair].sellHead
    sellPrice = sellHead.price
    
    price = sellPrice * factor
    newPrice = tradableBuyPrice(exchange, assetPair, price)

    oldBuyBack = currentBackOrders[exchange][assetPair].buyBack
    if oldBuyBack?
        oldVolume = oldBuyBack.volume
        newVolume = sellHead.volume
        oldPrice = oldBuyBack.price
        totalVolume = newVolume + oldVolume
        oldFraction = oldVolume / totalVolume
        newFraction = newVolume / totalVolume
        price = newFraction * newPrice + oldFraction * oldPrice
        return tradableBuyPrice(exchange, assetPair, price)
    else return newPrice

calculateSellBackPrice = (exchange, assetPair) ->
    factor = getSellBackPriceFactor(exchange, assetPair)

    buyHead = currentHeads[exchange][assetPair].buyHead
    buyPrice = buyHead.price

    price = buyPrice * factor
    newPrice = tradableSellPrice(exchange, assetPair, price) 

    oldSellBack = currentBackOrders[exchange][assetPair].sellBack
    if oldSellBack?
        oldVolume = oldSellBack.volume
        newVolume = buyHead.volume
        oldPrice = oldSellBack.price
        totalVolume = newVolume + oldVolume
        oldFraction = oldVolume / totalVolume
        newFraction = newVolume / totalVolume
        price = newFraction * newPrice + oldFraction * oldPrice
        return tradableSellPrice(exchange, assetPair, price)
    else return newPrice

calculateBuyHeadPrice = (exchange, assetPair) ->
    factor = getBuyHeadPriceFactor(exchange, assetPair)

    latestBid = utl.getLatestBidPrice(exchange, assetPair)
    latestClose = utl.getLatestClosingPrice(exchange, assetPair)

    if latestBid > latestClose then price = latestClose * factor
    else price = latestBid * factor

    return tradableBuyPrice(exchange, assetPair, price)

calculateSellHeadPrice = (exchange, assetPair) ->
    factor = getSellHeadPriceFactor(exchange, assetPair)

    latestAsk = utl.getLatestAskPrice(exchange, assetPair)
    latestClose = utl.getLatestClosingPrice(exchange, assetPair)

    if latestAsk < latestClose then price = latestClose * factor
    else price = latestAsk * factor

    return tradableSellPrice(exchange, assetPair, price)

############################################################
#region priceHelperFunctions
getBuyHeadPriceFactor = (exchange, assetPair) ->
    baseDistancePercent = getBaseDistancePercent(exchange, assetPair)
    magnifier = getMagnifier(exchange, assetPair)
    iteration = currentIterations[exchange][assetPair].buy
    if iteration == 0 then return 1.0
    
    magnification = Math.pow(magnifier, iteration)
    distancePercent = baseDistancePercent * magnification
    
    return (1.0 / utl.plusPercentFactor(distancePercent))

getSellHeadPriceFactor = (exchange, assetPair) ->
    baseDistancePercent = getBaseDistancePercent(exchange, assetPair)
    magnifier = getMagnifier(exchange, assetPair)
    iteration = currentIterations[exchange][assetPair].sell
    if iteration == 0 then return 1.0

    magnification = Math.pow(magnifier, iteration)
    distancePercent = baseDistancePercent * magnification
    
    return utl.plusPercentFactor(distancePercent)

getBuyBackPriceFactor = (exchange, assetPair) ->
    backOrderDistancePercent = getBackOrderDistancePercent(exchange, assetPair)
    return utl.plusPercentFactor(-backOrderDistancePercent)

getSellBackPriceFactor = (exchange, assetPair) ->
    backOrderDistancePercent = getBackOrderDistancePercent(exchange, assetPair)
    return utl.plusPercentFactor(backOrderDistancePercent)

#endregion


#endregion

############################################################
#region calculateVolumes
calculateBuyHeadVolume = (exchange, assetPair) ->
    magnifier = getMagnifier(exchange, assetPair)
    minVolume = getMinVolume(exchange, assetPair)
    
    iteration = currentIterations[exchange][assetPair].buy
    magnifiedVolume = minVolume * Math.pow(magnifier, iteration)
        
    return tradableBuyVolume(exchange, assetPair, magnifiedVolume)

calculateSellHeadVolume = (exchange, assetPair) ->
    magnifier = getMagnifier(exchange, assetPair)
    minVolume = getMinVolume(exchange, assetPair)
    
    iteration = currentIterations[exchange][assetPair].sell
    magnifiedVolume = minVolume * Math.pow(magnifier, iteration)
        
    return tradableSellVolume(exchange, assetPair, magnifiedVolume)

calculateBuyBackVolume = (exchange, assetPair) ->
    feePercent = cfg[exchange].makerFeePercent
    feeFactor = 1.0 / utl.plusPercentFactor(-feePercent)

    oldSellHead = currentHeads[exchange][assetPair].sellHead
    oldBuyBack = currentBackOrders[exchange][assetPair].buyBack
    
    volume = oldSellHead.volume * feeFactor
    if oldBuyBack? then volume += oldBuyBack.volume

    return tradableBuyVolume(exchange, assetPair, volume)

calculateSellBackVolume = (exchange, assetPair) ->
    feePercent = cfg[exchange].makerFeePercent
    feeFactor = utl.plusPercentFactor(-feePercent)

    oldBuyHead = currentHeads[exchange][assetPair].buyHead
    oldSellBack = currentBackOrders[exchange][assetPair].sellBack

    volume = oldBuyHead.volume * feeFactor
    if oldSellBack? then volume += oldSellBack.volume

    return tradableSellVolume(exchange, assetPair, volume)

#endregion

#endregion

############################################################
#region budgetFunctions
registerEatenBuyHead = (eatenIdea) ->
    strategy = eatenIdea.owner
    exchange = eatenIdea.exchange
    assetPair = eatenIdea.assetPair
    assets = assetPair.split("-")

    feePercent = cfg[exchange].makerFeePercent
    feeFactor = utl.plusPercentFactor(-feePercent)

    usedAsset = assets[1]
    wonAsset = assets[0]
    wonVolume = eatenIdea.volume * feeFactor
    usedVolume = eatenIdea.volume * eatenIdea.price

    budgetManager.registerTrade(strategy, exchange, assetPair, wonVolume, -usedVolume)

    budgetManager.free(strategy, exchange, wonAsset, wonVolume)
    
    # ## allocate volume for sellBack already here
    # oldSellBack = currentBackOrders[exchange][assetPair].sellBack
    # if oldSellBack?
    #     oldSellBackVolume = oldSellBack.volume
    #     log "freeing Budget from oldSellBack: "+oldSellBackVolume+" "+wonAsset
    #     budgetManager.free(strategy, exchange, wonAsset, oldSellBackVolume)

    # sellBackVolume = calculateSellBackVolume(exchange, assetPair)

    # budgetManager.allocate(strategy, exchange, wonAsset, sellBackVolume)

    # budgetManager.printCurrentBudgets()
    return

registerEatenSellHead = (eatenIdea) ->
    strategy = eatenIdea.owner
    exchange = eatenIdea.exchange
    assetPair = eatenIdea.assetPair
    assets = assetPair.split("-")

    feePercent = cfg[exchange].makerFeePercent
    feeFactor = utl.plusPercentFactor(-feePercent)
    
    usedAsset = assets[0]
    wonAsset = assets[1]    
    usedVolume = eatenIdea.volume
    wonVolume = eatenIdea.volume * eatenIdea.price * feeFactor

    budgetManager.registerTrade(strategy, exchange, assetPair, -usedVolume, wonVolume)

    budgetManager.free(strategy, exchange, wonAsset, wonVolume)

    # ## allocate volume for buyBack already here
    # oldBuyBack = currentBackOrders[exchange][assetPair].buyBack
    # if oldBuyBack?
    #     oldBuyBackVolume = oldBuyBack.volume * oldBuyBack.price
    #     log "freeing budget from oldBuyBack: "+oldBuyBackVolume+" "+wonAsset
    #     budgetManager.free(strategy, exchange, wonAsset, oldBuyBackVolume)

    # buyBackPrice = calculateBuyBackPrice(exchange, assetPair)
    # buyBackVolume = calculateBuyBackVolume(exchange, assetPair)
    # usedBuyBackVolume = buyBackVolume * buyBackPrice

    # budgetManager.allocate(strategy, exchange, wonAsset, usedBuyBackVolume)    
    return

############################################################
registerEatenBuyBack = (eatenIdea) ->
    strategy = eatenIdea.owner
    exchange = eatenIdea.exchange
    assetPair = eatenIdea.assetPair
    assets = assetPair.split("-")

    feePercent = cfg[exchange].makerFeePercent
    feeFactor = utl.plusPercentFactor(-feePercent)

    log "registerEatenBuyBack"
    log "feeFactor: "+feeFactor
    
    usedAsset = assets[1]
    wonAsset = assets[0]
    wonVolume = eatenIdea.volume * feeFactor
    usedVolume = eatenIdea.volume * eatenIdea.price

    log "registering trade for: "+usedVolume+" "+usedAsset+" -> "+wonVolume+" "+wonAsset 
    budgetManager.registerTrade(strategy, exchange, assetPair, wonVolume, -usedVolume)

    log "freeing budget from trade: "+wonVolume+" "+wonAsset 
    budgetManager.free(strategy, exchange, wonAsset, wonVolume)

    budgetManager.printCurrentBudgets()
    return

registerEatenSellBack = (eatenIdea) ->
    strategy = eatenIdea.owner
    exchange = eatenIdea.exchange
    assetPair = eatenIdea.assetPair
    assets = assetPair.split("-")

    feePercent = cfg[exchange].makerFeePercent
    feeFactor = utl.plusPercentFactor(-feePercent)
    
    log "registerEatenSellBack"
    log "feeFactor: "+feeFactor

    usedAsset = assets[0]
    wonAsset = assets[1]    
    usedVolume = eatenIdea.volume
    wonVolume = eatenIdea.volume * eatenIdea.price * feeFactor

    log "registering trade for: "+usedVolume+" "+usedAsset+" -> "+wonVolume+" "+wonAsset 
    budgetManager.registerTrade(strategy, exchange, assetPair, -usedVolume, wonVolume)

    log "freeing budget from trade: "+wonVolume+" "+wonAsset     
    budgetManager.free(strategy, exchange, wonAsset, wonAsset)

    budgetManager.printCurrentBudgets()
    return
    
############################################################
freeAllocatedBuyBudget = (buyIdea) ->
    return unless buyIdea
    strategy = buyIdea.owner
    exchange = buyIdea.exchange
    assetPair = buyIdea.assetPair
    assets = assetPair.split("-")
    asset = assets[1]
    volume = buyIdea.volume * buyIdea.price

    budgetManager.free(strategy, exchange, asset, volume)
    return

freeAllocatedSellBudget = (sellIdea) ->
    return unless sellIdea? 
    strategy = sellIdea.owner
    exchange = sellIdea.exchange
    assetPair = sellIdea.assetPair
    assets = assetPair.split("-")
    asset = assets[0]
    volume = sellIdea.volume

    budgetManager.free(strategy, exchange, asset, volume)
    return

############################################################
allocateBuyBudget = (idea) ->
    asset = idea.assetPair.split("-")[1]
    volume = idea.volume * idea.price
    budgetManager.allocate(idea.owner, idea.exchange, asset, volume)    
    return

allocateSellBudget = (idea) ->
    asset = idea.assetPair.split("-")[0]
    budgetManager.allocate(idea.owner, idea.exchange, asset, idea.volume)    
    return

#endregion

############################################################
#region eventHandlers
onFill = (idea) ->
    # log "onFill"
    # olog idea
    # log " - - - "

    exchange = idea.exchange
    assetPair = idea.assetPair
    return unless currentIdeas[exchange]?
    return unless currentIdeas[exchange][assetPair]?
    
    heads = currentHeads[exchange][assetPair]
    backOrders = currentBackOrders[exchange][assetPair]

    if heads.sellHead and Object.is(heads.sellHead, idea)
        return if heads.sellHead.eaten
        heads.sellHead.eaten = true
    if heads.buyHead and Object.is(heads.buyHead, idea)
        return if heads.buyHead.eaten
        heads.buyHead.eaten = true

    if backOrders.sellBack and Object.is(backOrders.sellBack, idea)
        return if backOrders.sellBack.eaten
        backOrders.sellBack.eaten = true
    if backOrders.buyBack and Object.is(backOrders.buyBack, idea)
        return if backOrders.buyBack.eaten
        backOrders.buyBack.eaten = true

    return

onCancel = (idea) ->
    # log "onCancel"
    # olog idea
    # log " - - - "

    exchange = idea.exchange
    assetPair = idea.assetPair
    return unless currentIdeas[exchange]?
    return unless currentIdeas[exchange][assetPair]?

    delete idea.isRealized
    delete idea.id

    if idea.cancelledSignal
        idea.cancelledSignal()
        return

    heads = currentHeads[exchange][assetPair]
    backOrders = currentBackOrders[exchange][assetPair]

    if heads.sellHead and Object.is(heads.sellHead, idea)
        freeAllocatedSellBudget(heads.sellHead)
        heads.sellHead = null
    if heads.buyHead and Object.is(heads.buyHead, idea)
        freeAllocatedBuyBudget(heads.buyHead)
        heads.buyHead = null

    if backOrders.sellBack and Object.is(backOrders.sellBack, idea)
        freeAllocatedSellBudget(backOrders.sellBack)
        backOrders.sellBack = null 
    if backOrders.buyBack and Object.is(backOrders.buyBack, idea)
        freeAllocatedBuyBudget(backOrders.buyBack)
        backOrders.buyBack = null

    return

onStupid = (idea) ->
    # log "onStupid"
    # olog idea
    # log " - - - "

    exchange = idea.exchange
    assetPair = idea.assetPair
    return unless currentIdeas[exchange]?
    return unless currentIdeas[exchange][assetPair]?

    heads = currentHeads[exchange][assetPair]
    backOrders = currentBackOrders[exchange][assetPair]

    if heads.sellHead and Object.is(heads.sellHead, idea)
        freeAllocatedSellBudget(heads.sellHead)
        heads.sellHead = null
    if heads.buyHead and Object.is(heads.buyHead, idea)
        freeAllocatedBuyBudget(heads.buyHead)
        heads.buyHead = null
    
    if backOrders.buyBack and Object.is(backOrders.buyBack, idea)
        delete backOrders.buyBack.isStupid
        backOrders.buyBack.goStubborn = true
    if backOrders.sellBack and Object.is(backOrders.sellBack, idea)
        delete backOrders.sellBack.isStupid
        backOrders.sellBack.goStubborn = true

    return

#endregion

############################################################
cancelIdea = (idea) ->
    isCancelling = true
    cancelSignal = new Promise (resolve, reject) ->
        idea.isBeingCancelled = true
        idea.cancelledSignal = resolve
        return
    await cancelSignal
    isCancelling = false
    return

#endregion

############################################################
#region exposedFunctions
robustarbitragestrategymodule.start = ->
    log "robustarbitragestrategymodule.start"
    heartbeatMS = params.heartbeatM * 60 * 1000
    heartBeatTimerId = setInterval(heartbeat, heartbeatMS)
    return

############################################################
robustarbitragestrategymodule.getCurrentIdeas = -> currentIdeas
robustarbitragestrategymodule.getRelevantIdeas = -> currentIdeas

############################################################
robustarbitragestrategymodule.noticeRelevantEvents = (events) ->
    # log "robustarbitragestrategymodule.noticeRelevantEvents"
    # olog events
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
        if event.type == "filled" or event.type == "instaFill" then onFill(event.idea)
        if event.type == "cancelled" or event.type == "instaCancel" then onCancel(event.idea)
        if event.type == "stupidIdeaNoticed" then onStupid(event.idea)    
    return
#endregion

module.exports = robustarbitragestrategymodule
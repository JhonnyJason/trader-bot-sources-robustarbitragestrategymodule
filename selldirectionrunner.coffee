selldirectionrunner = {}

############################################################
#region modules
stateModule = require("persistentstatemodule")
budgetManager = require("budgetmanagermodule")
utl = require("utilmodule")
bot = require("telegrambotmodule")

############################################################
situations = null

#endregion

############################################################
class SellThread
    constructor: (@exch, @pair, params) ->
        @state = stateModule.load(@exch+">"+@pair+"_sellThread")
        @voumePrecision = @getVolumePrecision(params)
        @pricePrecision = @getPricePrecision(params)
        @minVolume = @getMinVolume(params)
        @baseDistancePercent = @getBaseDistancePercent(params)
        @magnifier = @getMagnifier(params)
        @backOrderDistancePercent = @getBackOrderDistancePercent(params)
        @active = @goSellDirection(params)

    saveState: -> stateModule.save(@exch+">"+@pair+"_sellThread", @state)

    run: ->
        loop
            try await @doNextSell()
            catch exception then await @handleException(exception)
        return

    doNextSell: ->
        # we have 2 cases:
        # 1. we just restarted the strategy then we already have a @state.head and may just wait for the signal that it was eaten?
        # 2. we come from last iteration where sell was eaten - so we need a new sellHead
        if @state.head == null then await @setNewSellHead()
        await @getSellEatenSignal()

        oldBuyBack = @state.backOrder
        if oldBuyBack? then await cancelOrder(oldBuyBack)    
        await @freeAllocatedBuyBudget(oldBuyBack)
        await @registerEatenSellHead()
        buyBack = @getNextBuyBack



    resetSellHead: ->
        return

    handleException: (exception) ->
        if exception.buyBackEaten then await @resetSellHead()
        if exception.partialFill then await @handlePartial(exception)
        if exception.stack then await @handleError(exception)
        return

    handleError: (error) ->
        bot.send(error.stack)
        return

    handlePartial: (exception) ->
        bot.send(exception)
        return

    getSellHeadEatenSignal: ->
        
        return


    getSecretSpace: ->
        await @ready
        secret = await getSecretSpace(this)
        return await decrypt(secret, @secretKeyHex)

    getSecret: (secretId) ->
        await @ready
        secret = await getSecret(secretId, this)
        return await decrypt(secret, @secretKeyHex)

    ############################################################
    #region parameterExtraction
    getVolumePrecision: (params) ->
        return params.volumePrecision unless params.specific[@exch]?
        return params.volumePrecision unless params.specific[@exch][@pair]?
        return params.volumePrecision unless params.specific[@exch][@pair].volumePrecision?
        return params.specific[@exch][@pair].volumePrecision    

    getPricePrecision: (params) ->
        return params.pricePrecision unless params.specific[@exch]?
        return params.pricePrecision unless params.specific[@exch][@pair]?
        return params.pricePrecision unless params.specific[@exch][@pair].pricePrecision?
        return params.specific[@exch][@pair].pricePrecision

    getMinVolume: (params) ->
        return params.minVolume unless params.specific[@exch]?
        return params.minVolume unless params.specific[@exch][@pair]?
        return params.minVolume unless params.specific[@exch][@pair].minVolume?
        return params.specific[@exch][@pair].minVolume

    getBaseDistancePercent: (params) ->
        return params.baseDistancePercent unless params.specific[@exch]?
        return params.baseDistancePercent unless params.specific[@exch][@pair]?
        return params.baseDistancePercent unless params.specific[@exch][@pair].baseDistancePercent?
        return params.specific[@exch][@pair].baseDistancePercent

    getMagnifier: (params) ->
        return params.magnifier unless params.specific[@exch]?
        return params.magnifier unless params.specific[@exch][@pair]?
        return params.magnifier unless params.specific[@exch][@pair].magnifier?
        return params.specific[@exch][@pair].magnifier

    getBackOrderDistancePercent: (params) ->
        return params.backOrderDistancePercent unless params.specific[@exch]?
        return params.backOrderDistancePercent unless params.specific[@exch][@pair]?
        return params.backOrderDistancePercent unless params.specific[@exch][@pair].backOrderDistancePercent?
        return params.specific[@exch][@pair].backOrderDistancePercent

    goSellDirection: (params) ->
        return params.sellDirection unless params.specific[@exch]?
        return params.sellDirection unless params.specific[@exch][@pair]?
        return params.sellDirection unless params.specific[@exch][@pair].sellDirection?
        return params.specific[@exch][@pair].sellDirection
    #endregion

############################################################
#region internalFunctions


#endregion

############################################################
selldirectionrunner.initialize = (exchange, assetPair, params) ->
    sellThread = new SellThread(exchange, assetPair, params)
    if sellThread.active == false then return null 
    return sellThread

module.exports = selldirectionrunner
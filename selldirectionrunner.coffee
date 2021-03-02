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

    ############################################################
    saveState: -> stateModule.save(@exch+">"+@pair+"_sellThread", @state)

    ############################################################
    run: ->
        # if !@active
        #     @state = {}
        #     @saveState()
        #     return
        if !@state.currentStep? then @state.currentStep = "INIT"
        while @active
            try switch @state.currentStep
                when "ALLOCATESELLHEADBUDGET" then await @allocateSellHeadBudget()
                when "CREATENEXTHEAD" then @createNextSell()
                when "AWAITSELL" then await @sellEatenSignal()
                when "POSTSELL" then await @postSell()
                when "FREEBUYBACKBUDGET" then await @freeBuyBackBudget()
                when "REGISTERSELLINBUDGET" then await @registerSellInBudget()
                when "ALLOCATENEWBUYBACKBUDGET" then @allocateNewBuyBackBudget()
                when "UPDATEBUYBACK" then await @updateBuyBack()
                when "AWAITBUYBACKREALIZATION" then await @buyBackRealized()

            catch exception then await @handleException(exception)
        return

    ############################################################
    postSell: ->
        if @state.backOrder? 
            await cancelOrder(@state.backOrder)
            @setStep("FREEBUYBUDGET")
        else @setStep("REGISTERSELLINBUDGET")
        return

    freeBuyBudget:  ->
        await @freeAllocatedBuyBudget(@state.backOrder)
        @setStep("REGISTERSELLINBUDGET")
        return

    registerSellInBudget: ->
        await @registerEatenSellHeadInBudget()
        @setStep("ALLOCATENEWBUYBACKBUDGET")

    updateBuyBack: ->            
        buyBack = @getNextBuyBack(@state.backOrder)
        await @

    sellStep: ->
        await sellEatenSignal()
        @setStep("AFTERSELL")
        return


    ############################################################
    setStep: (step) ->
        @state.currentStep = step
        @saveState()
        return

    ############################################################
    handleException: (exception) ->
        if exception.buyBackEaten then await @terminateThread()
        if exception.userCancel then await @handleUserCancel()
        if exception.partialFill then await @handlePartial(exception)
        if exception.stack then await @handleError(exception)
        return

    handleError: (error) ->
        bot.send(error.stack)
        return

    handlePartial: (exception) ->
        bot.send(exception)
        return

    sellEatenSignal: -> return new Promise (resolve, reject) ->
        @notifySold = resolve
        @notifyException = reject
        return

    

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
selldirectionrunner.create = (exch, pair, params) -> new SellThread(exch, pair, params)

module.exports = selldirectionrunner
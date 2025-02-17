return {
    groupName = "ACF.Ballistics.OnImpact",

    beforeEach = function()
        stub( ACF.Ballistics, "BulletClient" )
        stub( ACF.Ballistics, "DoBulletsFlight" )
    end,

    cases = {
        {
            name = "Uses Ammo.WorldImpact if Type is World",
            func = function()
                local Bullet = {}
                local Trace = {}
                local Ammo = {
                    WorldImpact = stub(),
                    PropImpact = stub(),
                    OnFlightEnd = stub()
                }
                local Type = "World"

                ACF.Ballistics.OnImpact( Bullet, Trace, Ammo, Type )
                expect( Ammo.WorldImpact ).to.haveBeenCalled()
                expect( Ammo.PropImpact ).toNot.haveBeenCalled()
            end
        },

        {
            name = "Uses Ammo.PropImpact if Type is not World",
            func = function()
                local Bullet = {}
                local Trace = {}
                local Ammo = {
                    WorldImpact = stub(),
                    PropImpact = stub(),
                    OnFlightEnd = stub()
                }
                local Type = "Test"

                ACF.Ballistics.OnImpact( Bullet, Trace, Ammo, Type )
                expect( Ammo.WorldImpact ).toNot.haveBeenCalled()
                expect( Ammo.PropImpact ).to.haveBeenCalled()
            end
        },

        {
            name = "Calls Bullet.OnPenetrated if present and Penetration",
            func = function()
                local Bullet = { OnPenetrated = stub() }
                local Trace = {}
                local Ammo = { PropImpact = stub().returns( "Penetrated" ) }
                local Type = "Test"

                ACF.Ballistics.OnImpact( Bullet, Trace, Ammo, Type )
                expect( Bullet.OnPenetrated ).to.haveBeenCalled()
            end
        },

        {
            name = "Calls Bullet.OnRicocheted if present and Ricochet",
            func = function()
                local Bullet = { OnRicocheted = stub() }
                local Trace = {}
                local Ammo = { PropImpact = stub().returns( "Ricochet" ) }
                local Type = "Test"

                ACF.Ballistics.OnImpact( Bullet, Trace, Ammo, Type )
                expect( Bullet.OnRicocheted ).to.haveBeenCalled()
            end
        },

        {
            name = "Calls Bullet.OnEndFlight if present and not Penetration/Ricochet",
            func = function()
                local Bullet = { OnEndFlight = stub() }
                local Trace = {}
                local Ammo = {
                    PropImpact = stub().returns( "Neither" ),
                    OnFlightEnd = stub()
                }
                local Type = "Test"

                ACF.Ballistics.OnImpact( Bullet, Trace, Ammo, Type )
                expect( Bullet.OnEndFlight ).to.haveBeenCalled()
            end
        }
    }
}
